require "test_helper"

class SimplefinItem::ImporterInactiveTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
  end

  def importer
    @importer ||= SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)
  end

  test "marks inactive when payload indicates closed or hidden" do
    account_data = { id: "a1", name: "Old Checking", balance: 0, currency: "USD", closed: true }
    importer.send(:import_account, account_data)

    stats = @sync.reload.sync_stats
    assert stats.dig("inactive", "a1"), "should be inactive when closed flag present"
  end

  test "marks inactive after three consecutive zero runs with no holdings" do
    account_data = { id: "a2", name: "Dormant", balance: 0, "available-balance": 0, currency: "USD" }

    2.times { importer.send(:import_account, account_data) }
    stats = @sync.reload.sync_stats
    assert_equal 2, stats.dig("zero_runs", "a2"), "should count zero runs"
    assert_equal false, stats.dig("inactive", "a2"), "should not be inactive before threshold"

    importer.send(:import_account, account_data)
    stats = @sync.reload.sync_stats
    assert_equal true, stats.dig("inactive", "a2"), "should be inactive at threshold"
  end

  test "resets zero_runs_count and inactive when activity returns" do
    account_data = { id: "a3", name: "Dormant", balance: 0, "available-balance": 0, currency: "USD" }
    3.times { importer.send(:import_account, account_data) }
    stats = @sync.reload.sync_stats
    assert_equal true, stats.dig("inactive", "a3")

    # Activity returns: non-zero balance or holdings
    active_data = { id: "a3", name: "Dormant", balance: 10, currency: "USD" }
    importer.send(:import_account, active_data)
    stats = @sync.reload.sync_stats
    assert_equal 0, stats.dig("zero_runs", "a3")
    assert_equal false, stats.dig("inactive", "a3")
  end
end


# Additional regression: no balances present should not increment zero_runs or mark inactive
class SimplefinItem::ImporterInactiveTest < ActiveSupport::TestCase
  test "does not count zero run when both balances are missing and no holdings" do
    account_data = { id: "a4", name: "Unknown", currency: "USD" } # no balance keys, no holdings

    importer.send(:import_account, account_data)
    stats = @sync.reload.sync_stats

    assert_equal 0, stats.dig("zero_runs", "a4").to_i
    assert_equal false, stats.dig("inactive", "a4")
  end
end
