require "test_helper"

class LunchflowItem::ImporterSyncWindowTest < ActiveSupport::TestCase
  setup do
    @item = LunchflowItem.create!(family: families(:dylan_family), name: "Test Lunchflow", api_key: "test_key_123")
    @lunchflow_account = @item.lunchflow_accounts.create!(account_id: "acct-1", name: "Test Account", currency: "EUR")
    @provider = mock()
  end

  test "an explicit sync window sets where a later fetch starts" do
    @lunchflow_account.upsert_lunchflow_transactions_snapshot!([
      { "id" => "tx-1", "amount" => -10, "currency" => "EUR", "date" => "2026-10-19", "merchant" => "Rewe" }
    ])
    @lunchflow_account.update!(transactions_synced_through: Time.zone.parse("2026-10-10 06:00"), history_synced_from: nil)
    expect_fetch_from(Date.new(2026, 9, 1))

    import_transactions(sync_start_date: Date.new(2026, 9, 1))
  end

  test "an explicit sync window sets where a first fetch starts, and records no history marker" do
    @item.update!(sync_start_date: Date.new(2026, 1, 15))
    expect_fetch_from(Date.new(2026, 9, 1))

    import_transactions(sync_start_date: Date.new(2026, 9, 1))

    assert_nil @lunchflow_account.reload.history_synced_from
  end

  test "the connection hands its import the sync window" do
    LunchflowItem::Importer.expects(:new)
      .with(@item, has_entries(sync_start_date: Date.new(2026, 9, 1)))
      .returns(stub(import: { success: true }))

    assert_equal({ success: true }, @item.import_latest_lunchflow_data(sync_start_date: Date.new(2026, 9, 1)))
  end

  private
    def expect_fetch_from(start_date)
      @provider.expects(:get_account_transactions)
        .with("acct-1", has_entries(start_date: start_date))
        .returns({ transactions: [] })
    end

    def import_transactions(sync_start_date:)
      LunchflowItem::Importer.new(@item, lunchflow_provider: @provider, sync_start_date: sync_start_date)
        .send(:fetch_and_store_transactions, @lunchflow_account)
    end
end
