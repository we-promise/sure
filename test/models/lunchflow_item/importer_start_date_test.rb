require "test_helper"

class LunchflowItem::ImporterStartDateTest < ActiveSupport::TestCase
  setup do
    @item = LunchflowItem.create!(
      family: families(:dylan_family),
      name: "Test Lunchflow",
      api_key: "test_key_123"
    )
    @lunchflow_account = @item.lunchflow_accounts.create!(
      account_id: "acct-1",
      name: "Test Account",
      currency: "EUR"
    )
    @provider = mock()
  end

  test "first sync fetches the full history" do
    expect_fetch_from(nil)

    import_transactions
  end

  test "later syncs fetch from a week before the last sync" do
    last_sync = Time.zone.parse("2026-10-20 06:00")
    store_previous_transaction
    @item.stubs(:last_synced_at).returns(last_sync)
    expect_fetch_from(last_sync - 7.days)

    import_transactions
  end

  private

    def expect_fetch_from(start_date)
      @provider.expects(:get_account_transactions)
        .with("acct-1", has_entries(start_date: start_date))
        .returns({ transactions: [] })
    end

    def import_transactions
      LunchflowItem::Importer.new(@item, lunchflow_provider: @provider)
        .send(:fetch_and_store_transactions, @lunchflow_account)
    end

    def store_previous_transaction
      @lunchflow_account.upsert_lunchflow_transactions_snapshot!([
        { "id" => "tx-1", "amount" => -10, "currency" => "EUR", "date" => "2026-10-19", "merchant" => "Rewe" }
      ])
    end
end
