require "test_helper"
require "ostruct"

class AutoMatchesHelperTest < ActionView::TestCase
  test "a match date gains the year only when it falls in another one" do
    travel_to Date.new(2026, 11, 24) do
      assert_equal I18n.l(Date.new(2026, 10, 30), format: :short), auto_match_date(Date.new(2026, 10, 30))
      assert_equal I18n.l(Date.new(2020, 10, 30), format: :short_with_year), auto_match_date(Date.new(2020, 10, 30))
    end

    travel_to Date.new(2027, 1, 2) do
      assert_equal I18n.l(Date.new(2026, 12, 31), format: :short_with_year), auto_match_date(Date.new(2026, 12, 31))
      assert_equal I18n.l(Date.new(2027, 1, 1), format: :short), auto_match_date(Date.new(2027, 1, 1))
    end
  end

  test "days apart counts the gap between the legs either way and is nil on the same day" do
    assert_equal 3, auto_match_days_apart(transfer_with(Date.new(2020, 10, 27), Date.new(2020, 10, 30)))
    assert_equal 3, auto_match_days_apart(transfer_with(Date.new(2020, 10, 30), Date.new(2020, 10, 27)))
    assert_nil auto_match_days_apart(transfer_with(Date.new(2020, 10, 30), Date.new(2020, 10, 30)))
    assert_nil auto_match_days_apart(OpenStruct.new(outflow_transaction: nil, inflow_transaction: nil))
  end

  private
    def transfer_with(outflow_date, inflow_date)
      OpenStruct.new(
        outflow_transaction: OpenStruct.new(entry: OpenStruct.new(date: outflow_date)),
        inflow_transaction: OpenStruct.new(entry: OpenStruct.new(date: inflow_date))
      )
    end
end
