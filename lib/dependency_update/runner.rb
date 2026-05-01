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

      @summary = []
      @held_back = []

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

    def run_ruby_updates_with_cooldown
      section("bundle update")
      before = gemfile_lock_versions
      system("bundle update")
      after = gemfile_lock_versions

      updated = after.select { |name, ver| before[name] && before[name] != ver }
      on_cooldown = cooldown_ages(updated) { |name, ver| gem_age_days(name, ver) }
      record_summary("gems", updated.size, on_cooldown)

      return if on_cooldown.empty?

      system("git checkout -- Gemfile.lock", out: File::NULL, err: File::NULL)
      to_update = updated.keys - on_cooldown.keys
      system("bundle update #{to_update.join(' ')}") if to_update.any?
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

      published_at = Time.parse(JSON.parse(response.body)["created_at"])
      (Time.now - published_at) / 86400
    rescue => e
      warn "  Could not check gem cooldown for #{name} #{version}: #{e.message}"
      nil
    end

    def run_yarn_updates_with_cooldown
      section("yarn upgrade")
      outdated_before = yarn_outdated_packages
      system("yarn upgrade --latest --silent", out: File::NULL, err: File::NULL)
      updated_count = `git diff --unified=0 yarn.lock 2>/dev/null | grep -c '^+  version'`.strip.to_i

      on_cooldown = cooldown_ages(outdated_before.transform_values { |i| i[:latest] }) { |name, ver| npm_age_days(name, ver) }
      record_summary("yarn", updated_count, on_cooldown)

      return if on_cooldown.empty?

      on_cooldown.each do |name, _|
        system("yarn upgrade #{name}@#{outdated_before[name][:current]} --silent", out: File::NULL, err: File::NULL)
      end
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

    def run_importmap_updates_with_cooldown
      section("importmap update")
      before = parse_importmap_versions
      system("bin/importmap update")
      after = parse_importmap_versions

      updated = after.select { |pkg, ver| before[pkg] && before[pkg] != ver }
      on_cooldown = cooldown_ages(updated) { |pkg, ver| npm_age_days(pkg, ver) }
      record_summary("importmap", updated.size, on_cooldown)

      return if on_cooldown.empty?

      on_cooldown.each { |pkg, _| system("bin/importmap pin #{pkg}@#{before[pkg]}", out: File::NULL) }
    end

    def parse_importmap_versions
      return {} unless File.exist?("config/importmap.rb")

      File.readlines("config/importmap.rb").each_with_object({}) do |line, pins|
        pkg_match = line.match(/^\s*pin\s+"([^"]+)"/)
        ver_match = line.match(/#\s*@(\d[\d.]*)/)
        pins[pkg_match[1]] = ver_match[1] if pkg_match && ver_match
      end
    end

    def npm_age_days(package, version)
      encoded = package.gsub("/", "%2F")
      response = https_get("registry.npmjs.org", "/#{encoded}")
      return nil unless response.code == "200"

      time_str = JSON.parse(response.body).dig("time", version)
      return nil unless time_str

      (Time.now - Time.parse(time_str)) / 86400
    rescue => e
      warn "  Could not check npm cooldown for #{package} #{version}: #{e.message}"
      nil
    end

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
          puts "    #{name} #{info[:version]} #{dim("(#{info[:age]} days old)")}"
        end
      end
      puts dim("─" * 42)
    end

    def section(title)
      puts cyan(bold(title))
      puts dim("─" * title.length)
    end

    def tty? = $stdout.isatty

    def bold(text)  = tty? ? "\e[1m#{text}\e[0m"  : text
    def dim(text)   = tty? ? "\e[2m#{text}\e[0m"  : text
    def cyan(text)  = tty? ? "\e[36m#{text}\e[0m" : text
    def green(text) = tty? ? "\e[32m#{text}\e[0m" : text
    def yellow(text)= tty? ? "\e[33m#{text}\e[0m" : text

    def https_get(host, path)
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(path)
      end
    end
  end
end
