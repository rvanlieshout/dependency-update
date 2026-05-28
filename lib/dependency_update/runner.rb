# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module DependencyUpdate
  class Runner
    COOLDOWN_DAYS = Integer(ENV.fetch("DEPENDENCY_COOLDOWN_DAYS", "7"))

    def run
      $stdout.sync = true
      puts bold("dependency-update") + " (cooldown: #{COOLDOWN_DAYS} days)"
      puts

      @summary    = []
      @held_back  = []
      @npm_cache  = {}
      @gem_cache  = {}

      run_ruby_updates_with_cooldown
      run_yarn_updates_with_cooldown if yarn_present?
      run_importmap_updates_with_cooldown if importmap_present?

      print_summary
    end

    private

    def yarn_present?
      File.exist?("yarn.lock")
    end

    def importmap_present?
      File.exist?("config/importmap.rb") && File.exist?("bin/importmap")
    end

    # ── Gems ─────────────────────────────────────────────────────────────────

    def run_ruby_updates_with_cooldown
      section("bundle update")
      before = gemfile_lock_versions
      system("bundle update")
      after = gemfile_lock_versions

      updated    = after.select { |name, ver| before[name] && before[name] != ver }
      on_cooldown = cooldown_ages(updated) { |name, ver| gem_age_days(name, ver) }
      record_summary("gems", updated.size, on_cooldown)

      return if on_cooldown.empty?

      system("git checkout -- Gemfile.lock", out: File::NULL, err: File::NULL)

      # Update non-cooldown gems normally
      to_update = updated.keys - on_cooldown.keys
      system("bundle update #{to_update.join(' ')}") if to_update.any?

      # For each cooldown gem, try to install the best allowed version
      on_cooldown.each do |name, info|
        best = gem_best_allowed_version(name)
        next unless best && Gem::Version.new(best) > Gem::Version.new(before[name])

        info[:best] = best
        apply_gem_version(name, best)
      end
    end

    def gemfile_lock_versions
      return {} unless File.exist?("Gemfile.lock")

      File.readlines("Gemfile.lock").each_with_object({}) do |line, versions|
        match = line.match(/^    (\S+) \(([\d.]+)\)$/)
        versions[match[1]] = match[2] if match
      end
    end

    def gem_age_days(name, version)
      path = "/api/v2/rubygems/#{URI.encode_uri_component(name)}/versions/#{URI.encode_uri_component(version)}.json"
      response = https_get("rubygems.org", path)
      return nil unless response.code == "200"

      (Time.now - Time.parse(JSON.parse(response.body)["created_at"])) / 86400
    rescue => e
      warn "  Could not check gem cooldown for #{name} #{version}: #{e.message}"
      nil
    end

    def gem_best_allowed_version(name)
      @gem_cache[name] ||= begin
        response = https_get("rubygems.org", "/api/v1/versions/#{URI.encode_uri_component(name)}.json")
        response.code == "200" ? JSON.parse(response.body) : nil
      end

      versions = @gem_cache[name]
      return nil unless versions

      cutoff = Time.now - (COOLDOWN_DAYS * 86400)
      versions
        .reject { |v| v["prerelease"] }
        .select { |v| Time.parse(v["created_at"]) <= cutoff rescue false }
        .max_by { |v| Gem::Version.new(v["number"]) rescue Gem::Version.new("0") }
        &.fetch("number")
    rescue => e
      warn "  Could not fetch gem versions for #{name}: #{e.message}"
      nil
    end

    def apply_gem_version(name, version)
      # Temporarily pin the gem in Gemfile, bundle install, then restore the Gemfile.
      marker   = "# __dep_update_pin__"
      original = File.read("Gemfile")

      # Match an existing declaration: gem "name" or gem 'name', <options>
      pattern = /^([ \t]*)gem\s+(['"])#{Regexp.escape(name)}\2(.*)$/

      pinned = original.sub(pattern) do
        indent, quote, rest = $1, $2, $3
        # Drop an existing version requirement (leading quoted string), keep options.
        options = rest.sub(/\A\s*,\s*(['"])[^'"]*\1/, "")
        "#{indent}gem #{quote}#{name}#{quote}, #{quote}= #{version}#{quote}#{options} #{marker}"
      end

      # Not already declared (transitive dependency): append a pin line.
      if pinned == original
        pinned += "\n" unless pinned.end_with?("\n")
        pinned += "gem \"#{name}\", \"= #{version}\" #{marker}\n"
      end

      File.write("Gemfile", pinned)
      system("bundle install --quiet", out: File::NULL)
    ensure
      File.write("Gemfile", original) if original
    end

    # ── Yarn ─────────────────────────────────────────────────────────────────

    def run_yarn_updates_with_cooldown
      section("yarn upgrade")
      outdated_before = yarn_outdated_packages
      system("yarn upgrade --latest --silent", out: File::NULL, err: File::NULL)
      updated_count = `git diff --unified=0 yarn.lock 2>/dev/null | grep -c '^+  version'`.strip.to_i

      on_cooldown = cooldown_ages(outdated_before.transform_values { |i| i[:latest] }) { |name, ver| npm_age_days(name, ver) }
      record_summary("yarn", updated_count, on_cooldown)

      return if on_cooldown.empty?

      on_cooldown.each do |name, info|
        best     = npm_best_allowed_version(name)
        prev     = outdated_before[name][:current]
        use_best = best && Gem::Version.new(best) > Gem::Version.new(prev)
        target   = use_best ? best : prev
        info[:best] = best if use_best
        set_package_json_version(name, target)
      end
      system("yarn install --silent", out: File::NULL, err: File::NULL)
    end

    def yarn_outdated_packages
      output = `yarn outdated --json 2>/dev/null`
      return {} if output.empty?

      output.each_line.filter_map do |line|
        data = JSON.parse(line)
        next unless data["type"] == "table"
        data["data"]["body"].map { |row| [ row[0], { current: row[1], latest: row[3] } ] }
      rescue JSON::ParseError
        nil
      end.flatten(1).to_h
    end

    def npm_package_data(package)
      @npm_cache[package] ||= begin
        encoded  = package.gsub("/", "%2F")
        response = https_get("registry.npmjs.org", "/#{encoded}")
        response.code == "200" ? JSON.parse(response.body) : nil
      end
    rescue => e
      warn "  Could not fetch npm data for #{package}: #{e.message}"
      nil
    end

    def npm_age_days(package, version)
      data     = npm_package_data(package)
      time_str = data&.dig("time", version)
      return nil unless time_str

      (Time.now - Time.parse(time_str)) / 86400
    rescue => e
      warn "  Could not check npm cooldown for #{package} #{version}: #{e.message}"
      nil
    end

    def npm_best_allowed_version(package)
      data = npm_package_data(package)
      return nil unless data

      cutoff = Time.now - (COOLDOWN_DAYS * 86400)
      data["time"]
        .reject { |k, _| %w[created modified].include?(k) }
        .select { |_, t| Time.parse(t) <= cutoff rescue false }
        .max_by { |ver, _| Gem::Version.new(ver) rescue Gem::Version.new("0") }
        &.first
    rescue
      nil
    end

    # ── Importmap ─────────────────────────────────────────────────────────────

    def run_importmap_updates_with_cooldown
      section("importmap update")
      before = parse_importmap_versions
      system("bin/importmap update")
      after = parse_importmap_versions

      updated    = after.select { |pkg, ver| before[pkg] && before[pkg] != ver }
      on_cooldown = cooldown_ages(updated) { |pkg, ver| npm_age_days(pkg, ver) }
      record_summary("importmap", updated.size, on_cooldown)

      return if on_cooldown.empty?

      on_cooldown.each do |pkg, info|
        best     = npm_best_allowed_version(pkg)
        prev     = before[pkg]
        use_best = best && Gem::Version.new(best) > Gem::Version.new(prev)
        target   = use_best ? best : prev
        info[:best] = best if use_best
        system("bin/importmap pin #{pkg}@#{target}", out: File::NULL)
      end
    end

    def parse_importmap_versions
      return {} unless File.exist?("config/importmap.rb")

      File.readlines("config/importmap.rb").each_with_object({}) do |line, pins|
        pkg_match = line.match(/^\s*pin\s+"([^"]+)"/)
        ver_match = line.match(/#\s*@(\d[\d.]*)/)
        pins[pkg_match[1]] = ver_match[1] if pkg_match && ver_match
      end
    end

    def set_package_json_version(name, version)
      return unless File.exist?("package.json")

      content = File.read("package.json")
      updated = content.gsub(/"#{Regexp.escape(name)}"\s*:\s*"[^"]*"/, "\"#{name}\": \"#{version}\"")
      File.write("package.json", updated)
    rescue => e
      warn "  Could not update package.json for #{name}: #{e.message}"
    end

    # ── Shared helpers ────────────────────────────────────────────────────────

    def cooldown_ages(updated, &age_fn)
      updated.each_with_object({}) do |(name, version), result|
        age = age_fn.call(name, version)
        result[name] = { version: version, age: age.round(1) } if age && age < COOLDOWN_DAYS
      end
    end

    def record_summary(kind, updated_count, on_cooldown)
      @held_back.concat(on_cooldown.to_a)
      line = if updated_count.zero?
               "#{kind}: nothing to update"
             elsif on_cooldown.any?
               "#{kind}: #{updated_count} updated, #{yellow("#{on_cooldown.size} held back")}"
             else
               "#{kind}: #{green("#{updated_count} updated")}"
             end
      @summary << line
    end

    def print_summary
      puts
      puts dim("─" * 42)
      puts bold("Summary")
      @summary.each { |line| puts "  #{line}" }

      if @held_back.any?
        puts
        puts "  #{yellow("held back")} — not yet #{COOLDOWN_DAYS} days old:"
        @held_back.each do |name, info|
          latest  = info[:version]
          age     = info[:age]
          best    = info[:best]
          note    = best ? " → installed #{green(best)}" : ""
          puts "    #{name} #{latest} #{dim("(#{age} days old)")}#{note}"
        end
      end
      puts dim("─" * 42)
    end

    def section(title)
      puts cyan(bold(title))
      puts dim("─" * title.length)
    end

    def tty?          = $stdout.isatty
    def bold(text)    = tty? ? "\e[1m#{text}\e[0m"  : text
    def dim(text)     = tty? ? "\e[2m#{text}\e[0m"  : text
    def cyan(text)    = tty? ? "\e[36m#{text}\e[0m" : text
    def green(text)   = tty? ? "\e[32m#{text}\e[0m" : text
    def yellow(text)  = tty? ? "\e[33m#{text}\e[0m" : text

    def https_get(host, path)
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(path)
      end
    end
  end
end
