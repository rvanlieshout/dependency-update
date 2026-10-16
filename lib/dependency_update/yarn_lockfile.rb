# frozen_string_literal: true

require "json"

module DependencyUpdate
  class YarnLockfile
    class Entry
      attr_reader :key_line, :lines

      def initialize(key_line, lines)
        @key_line = key_line
        @lines = lines
      end

      def specifiers
        key_line.delete_suffix(":").split(/,\s*/).map { |spec| spec.delete_prefix('"').delete_suffix('"') }
      end

      def name = specifiers.first[/\A(@?[^@]+)@/, 1]

      def ranges = specifiers.map { |spec| spec.delete_prefix("#{name}@") }

      def version = field("version")

      def resolved = field("resolved")

      def dependency_names
        lines.filter_map do |line|
          match = line.match(/\A {4}("(?:[^"\\]|\\.)*"|\S+) /)
          match && unwrap(match[1])
        end
      end

      def field(key)
        line = lines.find { |candidate| candidate.start_with?("  #{key} ") }
        line && unwrap(line.delete_prefix("  #{key} "))
      end

      def replace(version:, resolved:, integrity:, dependencies:, optional_dependencies:)
        @lines = ["  version #{YarnLockfile.wrap(version)}", "  resolved #{YarnLockfile.wrap(resolved)}"]
        @lines << "  integrity #{YarnLockfile.wrap(integrity)}" if integrity
        { "dependencies" => dependencies, "optionalDependencies" => optional_dependencies }.each do |section, deps|
          next if deps.nil? || deps.empty?

          @lines << "  #{section}:"
          deps.sort.each { |dep, range| @lines << "    #{YarnLockfile.wrap(dep)} #{YarnLockfile.wrap(range)}" }
        end
      end

      def to_s = [key_line, *lines].join("\n")

      private

      def unwrap(value) = value.start_with?('"') ? JSON.parse(value) : value
    end

    def self.read(path = "yarn.lock") = new(File.read(path))

    def self.wrap(value)
      needs_quotes = value.start_with?("true", "false") ||
                     value.match?(/[:\s\\",\[\]]/) ||
                     !value.match?(/\A[a-zA-Z]/)
      needs_quotes ? value.to_json : value
    end

    def initialize(text)
      @chunks = text.split(/(\n{2,}|\n\z)/).map do |chunk|
        first, *rest = chunk.split("\n")
        entry_chunk?(first) ? Entry.new(first, rest) : chunk
      end
    end

    def entries = @chunks.grep(Entry)

    def to_s = @chunks.map(&:to_s).join

    def write(path = "yarn.lock") = File.write(path, to_s)

    private

    def entry_chunk?(first_line)
      !first_line.nil? && !first_line.start_with?("#", " ") && first_line.end_with?(":")
    end
  end
end
