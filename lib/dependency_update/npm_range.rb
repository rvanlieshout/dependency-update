# frozen_string_literal: true

module DependencyUpdate
  module NpmRange
    PARTIAL = /\A[v=]?(\d+|[xX*])(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\z/

    Version = Struct.new(:major, :minor, :patch, :pre) do
      include Comparable

      def release = [major, minor, patch]

      def <=>(other)
        result = release <=> other.release
        return result unless result.zero?
        return 0 if pre == other.pre
        return 1 if pre.nil?
        return -1 if other.pre.nil?

        compare_prerelease(pre.split("."), other.pre.split("."))
      end

      private

      def compare_prerelease(left, right)
        left.zip(right).each do |a, b|
          return 1 if b.nil?

          result = if a.match?(/\A\d+\z/) && b.match?(/\A\d+\z/)
                     a.to_i <=> b.to_i
                   elsif a.match?(/\A\d+\z/)
                     -1
                   elsif b.match?(/\A\d+\z/)
                     1
                   else
                     a <=> b
                   end
          return result unless result.zero?
        end
        left.size <=> right.size
      end
    end

    Comparator = Struct.new(:operator, :bound, :explicit_prerelease)

    module_function

    def satisfies?(version, range)
      target = parse_version(version)
      sets = comparator_sets(range)
      return nil unless target && sets

      sets.any? do |set|
        set.all? { |comparator| target.public_send(comparator.operator, comparator.bound) } &&
          prerelease_allowed?(target, set)
      end
    end

    def parse_version(string)
      match = PARTIAL.match(string.to_s.strip)
      return nil unless match

      numbers = match[1..3]
      return nil if numbers.any? { |part| part.nil? || wildcard?(part) }

      Version.new(*numbers.map(&:to_i), match[4])
    end

    def comparator_sets(range)
      alternatives = range.to_s.split("||")
      alternatives = [""] if alternatives.empty?
      alternatives.map do |alternative|
        comparators(alternative.strip) || (return nil)
      end
    end

    def comparators(alternative)
      if (hyphen = alternative.match(/\A(\S+)\s+-\s+(\S+)\z/))
        lower = comparator(">=#{hyphen[1]}")
        upper = comparator("<=#{hyphen[2]}")
        return lower && upper && lower + upper
      end

      tokens = alternative.gsub(/(<=|>=|<|>|=|\^|~>?)\s+/, '\1').split(/\s+/)
      tokens.flat_map { |token| comparator(token) || (return nil) }
    end

    def comparator(token)
      operator, rest = token.match(/\A(<=|>=|<|>|=|\^|~>?)?(.*)\z/).captures
      match = PARTIAL.match(rest)
      return nil unless match

      parts = partial_numbers(match[1..3])
      pre = match[4]

      case operator
      when "^" then caret(parts, pre)
      when "~", "~>" then tilde(parts, pre)
      when nil, "=" then x_range(parts, pre)
      else primitive(operator, parts, pre)
      end
    end

    def partial_numbers(parts)
      numbers = []
      parts.each do |part|
        break if part.nil? || wildcard?(part)

        numbers << part.to_i
      end
      numbers
    end

    def wildcard?(part) = %w[x X *].include?(part)

    def floor(parts, pre = nil)
      Version.new(parts[0] || 0, parts[1] || 0, parts[2] || 0, parts.size == 3 ? pre : nil)
    end

    def ceiling(major, minor = 0, patch = 0) = Version.new(major, minor, patch, "0")

    def at_least(parts, pre) = Comparator.new(:>=, floor(parts, pre), !pre.nil? && parts.size == 3)

    def below(version) = Comparator.new(:<, version, false)

    def x_range(parts, pre)
      case parts.size
      when 0 then []
      when 1 then [at_least(parts, nil), below(ceiling(parts[0] + 1))]
      when 2 then [at_least(parts, nil), below(ceiling(parts[0], parts[1] + 1))]
      else [Comparator.new(:==, floor(parts, pre), !pre.nil?)]
      end
    end

    def tilde(parts, pre)
      case parts.size
      when 0 then []
      when 1 then [at_least(parts, nil), below(ceiling(parts[0] + 1))]
      else [at_least(parts, pre), below(ceiling(parts[0], parts[1] + 1))]
      end
    end

    def caret(parts, pre)
      return [] if parts.empty?

      major, minor, patch = parts
      upper = if major.positive? || minor.nil?
                ceiling(major + 1)
              elsif minor.positive? || patch.nil?
                ceiling(0, minor + 1)
              else
                ceiling(0, 0, patch + 1)
              end
      [at_least(parts, pre), below(upper)]
    end

    def primitive(operator, parts, pre)
      return(%w[< >].include?(operator) ? [below(Version.new(0, 0, 0, "0"))] : []) if parts.empty?

      return [Comparator.new(operator.to_sym, floor(parts, pre), !pre.nil?)] if parts.size == 3

      next_partial = parts.size == 1 ? ceiling(parts[0] + 1) : ceiling(parts[0], parts[1] + 1)
      case operator
      when ">=" then [at_least(parts, nil)]
      when ">" then [Comparator.new(:>=, Version.new(*next_partial.release, nil), false)]
      when "<" then [below(Version.new(*floor(parts).release, "0"))]
      when "<=" then [below(next_partial)]
      end
    end

    def prerelease_allowed?(target, set)
      return true if target.pre.nil?

      set.any? { |comparator| comparator.explicit_prerelease && comparator.bound.release == target.release }
    end
  end
end
