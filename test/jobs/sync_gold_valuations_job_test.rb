require "test_helper"

class SyncGoldValuationsJobTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
    @account.investment.update!(subtype: "gold", gold_form: "physical")
    @account.physical_gold_lots.create!(description: "Bar", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
  end

  test "refreshes active physical gold accounts with purchases" do
    valuation = mock
    GoldValuation.expects(:new).with(account: @account).returns(valuation)
    valuation.expects(:refresh!)

    SyncGoldValuationsJob.new.perform
  end

  test "logs failures without stopping other valuation refreshes" do
    GoldValuation.stubs(:new).raises(GoldValuation::Error, "provider unavailable")

    assert_difference "DebugLogEntry.count", 1 do
      SyncGoldValuationsJob.new.perform
    end
  end
end
