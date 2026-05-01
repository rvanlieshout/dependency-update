# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module DependencyUpdate
  class Runner
    COOLDOWN_DAYS = Integer(ENV.fetch("DEPENDENCY_COOLDOWN_DAYS", "7"))

    def run
      puts "Dependency update (#{COOLDOWN_DAYS}-day cooldown)"
      run_ruby_updates_with_cooldown
      run_yarn_updates_with_cooldown if yarn_present?
      run_importmap_updates_with_cooldown if importmap_present?
    end

    private

    def yarn_present?
      File.exist?("yarn.lock")
    end

    def importmap_present?
      File.exist?("config/importmap.rb") && File.exist?("bin/importmap")
    end

    def run_ruby_updates_with_cooldown
      puts "Running bundle update"
      before = gemfile_lock_versions
      system("bundle update")
      after = gemfile_lock_versions

      updated = after.select { |name, ver| before[name] && before[name] != ver }
      on_cooldown = updated.select { |name, ver| gem_in_cooldown?(name, ver) }
      return if on_cooldown.empty?

      log_on_cooldown("gem", on_cooldown.to_a)
      system("git checkout -- Gemfile.lock")
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

    def gem_in_cooldown?(name, version)
      path = "/api/v2/rubygems/#{URI.encode_uri_component(name)}/versions/#{URI.encode_uri_component(version)}.json"
      response = https_get("rubygems.org", path)
      return false unless response.code == "200"

      published_at = Time.parse(JSON.parse(response.body)["created_at"])
      within_cooldown?(published_at, "#{name} #{version}")
    rescue => e
      warn "  Could not check gem cooldown for #{name} #{version}: #{e.message}"
      false
    end

    def run_yarn_updates_with_cooldown
      puts "Running yarn upgrade"
      outdated_before = yarn_outdated_packages
      system("yarn upgrade --latest")
      return if outdated_before.empty?

      on_cooldown = outdated_before.select { |name, info| npm_in_cooldown?(name, info[:latest]) }
      return if on_cooldown.empty?

      log_on_cooldown("yarn package", on_cooldown.map { |n, i| [ n, i[:latest] ] })
      on_cooldown.each { |name, info| system("yarn upgrade #{name}@#{info[:current]}") }
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
      puts "Running importmap update"
      before = parse_importmap_versions
      system("bin/importmap update")
      after = parse_importmap_versions

      updated = after.select { |pkg, ver| before[pkg] && before[pkg] != ver }
      return if updated.empty?

      on_cooldown = updated.select { |pkg, ver| npm_in_cooldown?(pkg, ver) }
      return if on_cooldown.empty?

      log_on_cooldown("importmap pin", on_cooldown.to_a)
      on_cooldown.each { |pkg, _| system("bin/importmap pin #{pkg}@#{before[pkg]}") }
    end

    def parse_importmap_versions
      return {} unless File.exist?("config/importmap.rb")

      File.readlines("config/importmap.rb").each_with_object({}) do |line, pins|
        pkg_match = line.match(/^\s*pin\s+"([^"]+)"/)
        ver_match = line.match(/#\s*@(\d[\d.]*)/)
        pins[pkg_match[1]] = ver_match[1] if pkg_match && ver_match
      end
    end

    def npm_in_cooldown?(package, version)
      encoded = package.gsub("/", "%2F")
      response = https_get("registry.npmjs.org", "/#{encoded}")
      return false unless response.code == "200"

      time_str = JSON.parse(response.body).dig("time", version)
      return false unless time_str

      within_cooldown?(Time.parse(time_str), "#{package} #{version}")
    rescue => e
      warn "  Could not check npm cooldown for #{package} #{version}: #{e.message}"
      false
    end

    def within_cooldown?(published_at, label)
      age_days = (Time.now - published_at) / 86400
      return false unless age_days < COOLDOWN_DAYS

      puts "  COOLDOWN: #{label} (#{age_days.round(1)} days old, minimum #{COOLDOWN_DAYS})"
      true
    end

    def log_on_cooldown(kind, items)
      puts "Holding back #{items.size} #{kind}(s) — released within the last #{COOLDOWN_DAYS} days:"
      items.each { |name, version| puts "  #{name} #{version}" }
    end

    def https_get(host, path)
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(path)
      end
    end
  end
end
