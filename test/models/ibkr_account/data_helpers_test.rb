# frozen_string_literal: true

require "test_helper"

class IbkrAccount::DataHelpersTest < ActiveSupport::TestCase
  class TestHelper
    include IbkrAccount::DataHelpers

    public :parse_decimal
  end

  setup do
    @helper = TestHelper.new
  end

  test "parse_decimal returns nil for nil input" do
    assert_nil @helper.parse_decimal(nil)
  end

  test "parse_decimal returns nil for blank string" do
    assert_nil @helper.parse_decimal("")
    assert_nil @helper.parse_decimal("   ")
  end

  test "parse_decimal returns nil for dash placeholder" do
    assert_nil @helper.parse_decimal("-")
  end

  test "parse_decimal converts parentheses notation to negative" do
    assert_equal BigDecimal("-1234.56"), @helper.parse_decimal("(1234.56)")
  end

  test "parse_decimal converts parentheses notation with comma-separated number" do
    assert_equal BigDecimal("-1234.56"), @helper.parse_decimal("(1,234.56)")
  end

  test "parse_decimal strips commas from positive numbers" do
    assert_equal BigDecimal("1234.56"), @helper.parse_decimal("1,234.56")
  end

  test "parse_decimal parses plain decimal string" do
    assert_equal BigDecimal("3351.00"), @helper.parse_decimal("3351.00")
  end

  test "parse_decimal returns nil for empty parentheses" do
    assert_nil @helper.parse_decimal("()")
  end

  test "parse_decimal returns nil for unclosed parenthesis" do
    assert_nil @helper.parse_decimal("(123")
  end

  test "parse_decimal returns nil for non-numeric string" do
    assert_nil @helper.parse_decimal("N/A")
    assert_nil @helper.parse_decimal("not_a_number")
  end
end
