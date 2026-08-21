# frozen_string_literal: true

require "test_helper"

class RedbarkAccount::DataHelpersTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestHelper
    include RedbarkAccount::DataHelpers

    # Make private methods public for testing
    public :parse_decimal, :parse_date, :extract_currency
  end

  setup do
    @helper = TestHelper.new
  end

  # ==========================================================================
  # parse_decimal tests
  # ==========================================================================

  test "parse_decimal returns nil for nil input" do
    assert_nil @helper.parse_decimal(nil)
  end

  test "parse_decimal parses string to BigDecimal" do
    result = @helper.parse_decimal("123.45")
    assert_instance_of BigDecimal, result
    assert_equal BigDecimal("123.45"), result
  end

  test "parse_decimal handles integer input" do
    result = @helper.parse_decimal(100)
    assert_instance_of BigDecimal, result
    assert_equal BigDecimal("100"), result
  end

  test "parse_decimal handles float input" do
    result = @helper.parse_decimal(99.99)
    assert_instance_of BigDecimal, result
    assert_in_delta 99.99, result.to_f, 0.001
  end

  test "parse_decimal returns BigDecimal unchanged" do
    input = BigDecimal("50.25")
    result = @helper.parse_decimal(input)
    assert_equal input, result
  end

  test "parse_decimal returns nil for invalid string" do
    assert_nil @helper.parse_decimal("not a number")
  end

  # ==========================================================================
  # parse_date tests
  # ==========================================================================

  test "parse_date returns nil for nil input" do
    assert_nil @helper.parse_date(nil)
  end

  test "parse_date returns Date unchanged" do
    input = Date.new(2024, 6, 15)
    result = @helper.parse_date(input)
    assert_equal input, result
  end

  test "parse_date parses ISO date string" do
    result = @helper.parse_date("2024-06-15")
    assert_instance_of Date, result
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date parses datetime string to date" do
    result = @helper.parse_date("2024-06-15T10:30:00Z")
    assert_instance_of Date, result
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date converts Time to Date" do
    input = Time.zone.parse("2024-06-15 10:30:00")
    result = @helper.parse_date(input)
    assert_instance_of Date, result
    assert_equal Date.new(2024, 6, 15), result
  end

  test "parse_date returns nil for invalid string" do
    assert_nil @helper.parse_date("not a date")
  end

  # ==========================================================================
  # extract_currency tests
  # ==========================================================================

  test "extract_currency returns fallback for nil currency" do
    result = @helper.extract_currency({}, fallback: "USD")
    assert_equal "USD", result
  end

  test "extract_currency extracts string currency" do
    result = @helper.extract_currency({ currency: "cad" })
    assert_equal "CAD", result
  end

  test "extract_currency extracts currency from hash with code key" do
    result = @helper.extract_currency({ currency: { code: "EUR" } })
    assert_equal "EUR", result
  end

  test "extract_currency handles indifferent access" do
    result = @helper.extract_currency({ "currency" => { "code" => "GBP" } })
    assert_equal "GBP", result
  end
end
