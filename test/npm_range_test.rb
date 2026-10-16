# frozen_string_literal: true

require "minitest/autorun"
require "dependency_update"

class NpmRangeTest < Minitest::Test
  def assert_satisfies(version, range)
    assert DependencyUpdate::NpmRange.satisfies?(version, range), "expected #{version} to satisfy #{range}"
  end

  def refute_satisfies(version, range)
    refute DependencyUpdate::NpmRange.satisfies?(version, range), "expected #{version} not to satisfy #{range}"
  end

  def test_caret
    assert_satisfies "1.5.458", "^1.5.439"
    refute_satisfies "1.5.438", "^1.5.439"
    refute_satisfies "2.0.0", "^1.5.439"
    assert_satisfies "0.8.6", "^0.8.5"
    refute_satisfies "0.9.0", "^0.8.5"
    assert_satisfies "0.0.3", "^0.0.3"
    refute_satisfies "0.0.4", "^0.0.3"
    assert_satisfies "0.9.9", "^0.x"
    refute_satisfies "1.0.0", "^0.x"
  end

  def test_tilde
    assert_satisfies "1.2.9", "~1.2.3"
    refute_satisfies "1.3.0", "~1.2.3"
    assert_satisfies "1.9.0", "~1"
    refute_satisfies "2.0.0", "~1"
  end

  def test_x_ranges_and_exact
    assert_satisfies "1.13.2", "1.13.2"
    refute_satisfies "1.13.1", "1.13.2"
    assert_satisfies "1.2.7", "1.2.x"
    refute_satisfies "1.3.0", "1.2"
    assert_satisfies "4.6.7", "*"
    assert_satisfies "4.6.7", ""
  end

  def test_comparators_and_intersections
    assert_satisfies "1.2.2", ">=0.6.2 <2.0.0"
    refute_satisfies "2.0.0", ">=0.6.2 <2.0.0"
    assert_satisfies "1.2.2", ">= 0.6.2 < 2.0.0"
    assert_satisfies "1.3.0", ">1.2"
    refute_satisfies "1.2.9", ">1.2"
    assert_satisfies "1.2.9", "<=1.2"
    refute_satisfies "1.3.0", "<=1.2"
    refute_satisfies "1.2.0", "<1.2"
  end

  def test_alternatives_and_hyphen
    assert_satisfies "3.0.1", "^2.0.0 || ^3.0.0"
    refute_satisfies "4.0.0", "^2.0.0 || ^3.0.0"
    assert_satisfies "2.3.0", "1.2.3 - 2.3"
    refute_satisfies "2.4.0", "1.2.3 - 2.3"
  end

  def test_prereleases
    refute_satisfies "2.0.0-beta.1", "^1.0.0"
    refute_satisfies "1.6.0-beta.1", "^1.5.0"
    assert_satisfies "1.5.0-beta.2", "^1.5.0-beta.1"
    refute_satisfies "1.5.0-beta.0", "^1.5.0-beta.1"
    assert_satisfies "157.0.8090-0", "157.0.8090-0"
  end

  def test_unparseable_ranges
    assert_nil DependencyUpdate::NpmRange.satisfies?("4.2.0", "npm:string-width@^4.2.0")
    assert_nil DependencyUpdate::NpmRange.satisfies?("1.0.0", "latest")
    assert_nil DependencyUpdate::NpmRange.satisfies?("not-a-version", "^1.0.0")
  end

  def test_version_ordering
    parse = ->(v) { DependencyUpdate::NpmRange.parse_version(v) }
    assert_operator parse["1.0.0"], :>, parse["1.0.0-rc.1"]
    assert_operator parse["1.0.0-rc.2"], :>, parse["1.0.0-rc.1"]
    assert_operator parse["1.0.0-rc.1"], :>, parse["1.0.0-beta"]
    assert_operator parse["1.0.0-beta"], :>, parse["1.0.0-1"]
    assert_operator parse["1.10.0"], :>, parse["1.9.0"]
  end
end
