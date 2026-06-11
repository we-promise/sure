require "test_helper"

module TaxWorkbook
  class ValueParserTest < ActiveSupport::TestCase
    setup do
      @parser = ValueParser.new
    end

    test "parses decimals including separators and blank values" do
      assert_equal BigDecimal("1234.50"), @parser.decimal("1,234.50")
      assert_equal BigDecimal("1200"), @parser.decimal(1200)
      assert_equal BigDecimal("0"), @parser.decimal(nil)
      assert_equal BigDecimal("0"), @parser.decimal("")
    end

    test "parses booleans from common workbook values" do
      assert_equal true, @parser.boolean("yes")
      assert_equal true, @parser.boolean("1")
      assert_equal false, @parser.boolean("0")
      assert_equal false, @parser.boolean("No")
    end

    test "parses dates months and quarters" do
      assert_equal Date.new(2026, 4, 10), @parser.date("2026-04-10")
      assert_equal Date.new(2026, 4, 1), @parser.month("2026-04")
      assert_equal Date.new(2026, 4, 1), @parser.month(Date.new(2026, 4, 18))
      assert_equal "Q1", @parser.quarter("q1")
    end

    test "normalizes tax identifiers" do
      assert_equal "27ABCDE1234F1Z5", @parser.gstin("27abcde1234f1z5")
      assert_equal "MUMR12345A", @parser.tan(" mumr12345a ")
      assert_equal "ABCDE1234F", @parser.pan("abcde1234f")
    end

    test "raises actionable errors for invalid workbook values" do
      assert_equal "must be a decimal number", assert_raises(ArgumentError) { @parser.decimal("12,34x") }.message
      assert_equal "must be true or false", assert_raises(ArgumentError) { @parser.boolean("maybe") }.message
      assert_equal "must be a date", assert_raises(ArgumentError) { @parser.date("not-a-date") }.message
      assert_equal "must be a month like YYYY-MM", assert_raises(ArgumentError) { @parser.month("2026/04") }.message
      assert_equal "must be Q1, Q2, Q3, or Q4", assert_raises(ArgumentError) { @parser.quarter("quarter 1") }.message
      assert_equal "must be a 15-character GSTIN", assert_raises(ArgumentError) { @parser.gstin("bad") }.message
      assert_equal "must be a 10-character TAN", assert_raises(ArgumentError) { @parser.tan("bad") }.message
      assert_equal "must be a 10-character PAN", assert_raises(ArgumentError) { @parser.pan("bad") }.message
    end
  end
end
