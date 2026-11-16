require "test_helper"

class RecurringPriceChangeTest < ActiveSupport::TestCase
  # One threshold for the notices and the bill row: a tenth either way.
  test "a change is material from a tenth either way" do
    { 109.99 => false, 110 => true, 90 => true, 90.01 => false }.each do |new_amount, material|
      change = RecurringPriceChange.new(previous_amount: 100, new_amount: new_amount)
      assert_equal material, change.material?, "100 to #{new_amount}"
    end
  end

  test "a change from nothing has no shift to measure" do
    change = RecurringPriceChange.new(previous_amount: 0, new_amount: 12)

    assert_equal 0, change.shift
    assert_not change.material?
  end
end
