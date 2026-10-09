require "test_helper"

class Security::SplitTest < ActiveSupport::TestCase
  setup do
    @security = Security.create!(ticker: "SPLT", name: "Split Test")
    @ex_date = Date.new(2025, 6, 10)
  end

  test "a split needs positive terms that are not one-for-one" do
    [ [ 0, 1 ], [ 2, 0 ], [ -2, 1 ], [ 3, 3 ] ].each do |numerator, denominator|
      split = @security.splits.new(ex_date: @ex_date, numerator: numerator, denominator: denominator, source: "manual")

      assert_not split.valid?, "#{numerator}:#{denominator} should be refused"
    end

    assert @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 10, source: "manual").valid?
  end

  test "one split per security per ex-date" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_not @security.splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
    assert Security.create!(ticker: "OTHR", name: "Other").splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
  end

  test "the database refuses a zero term that bypasses the model" do
    split = @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_raises(ActiveRecord::StatementInvalid) { split.update_columns(denominator: 0) }
  end

  test "the ratio is exact" do
    split = @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 3, source: "manual")

    assert_equal Rational(1, 3), split.ratio
  end

  test "deleting the security deletes its splits" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_difference "Security::Split.count", -1 do
      @security.destroy
    end
  end

  test "the split factor between two dates takes the splits after the first and on or before the second" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")
    @security.splits.create!(ex_date: @ex_date + 30, numerator: 3, denominator: 1, source: "manual")

    assert_equal 1, @security.split_factor_between(@ex_date - 10, @ex_date - 1)
    assert_equal 2, @security.split_factor_between(@ex_date - 1, @ex_date)
    assert_equal 1, @security.split_factor_between(@ex_date, @ex_date + 29)
    assert_equal 6, @security.split_factor_between(@ex_date - 1, @ex_date + 30)
  end
end
