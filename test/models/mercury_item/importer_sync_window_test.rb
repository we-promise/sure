require "test_helper"

class MercuryItem::ImporterSyncWindowTest < ActiveSupport::TestCase
  setup do
    @item = MercuryItem.create!(family: families(:dylan_family), name: "Test Mercury", token: "tok")
    @mercury_account = @item.mercury_accounts.create!(account_id: "acct-1", name: "Test Account", currency: "USD")
    @provider = mock()
  end

  test "an explicit sync window sets where a later fetch starts" do
    @mercury_account.upsert_mercury_transactions_snapshot!([ { "id" => "tx-1", "amount" => -10, "status" => "sent" } ])
    @item.stubs(:last_synced_at).returns(Time.zone.parse("2026-10-10 06:00"))
    expect_fetch_from(Date.new(2026, 9, 1))

    import_transactions(sync_start_date: Date.new(2026, 9, 1))
  end

  test "an explicit sync window sets where a first fetch starts" do
    expect_fetch_from(Date.new(2026, 9, 1))

    import_transactions(sync_start_date: Date.new(2026, 9, 1))
  end

  test "without a window a later fetch still starts a week before the last sync" do
    @mercury_account.upsert_mercury_transactions_snapshot!([ { "id" => "tx-1", "amount" => -10, "status" => "sent" } ])
    last_synced_at = Time.zone.parse("2026-10-10 06:00")
    @item.stubs(:last_synced_at).returns(last_synced_at)
    expect_fetch_from(last_synced_at - 7.days)

    import_transactions(sync_start_date: nil)
  end

  test "the connection hands its import the sync window" do
    MercuryItem::Importer.expects(:new)
      .with(@item, has_entries(sync_start_date: Date.new(2026, 9, 1)))
      .returns(stub(import: { success: true }))

    assert_equal({ success: true }, @item.import_latest_mercury_data(sync_start_date: Date.new(2026, 9, 1)))
  end

  private
    def expect_fetch_from(start_date)
      @provider.expects(:get_account_transactions)
        .with("acct-1", has_entries(start_date: start_date))
        .returns({ transactions: [] })
    end

    def import_transactions(sync_start_date:)
      MercuryItem::Importer.new(@item, mercury_provider: @provider, sync_start_date: sync_start_date)
        .send(:fetch_and_store_transactions, @mercury_account)
    end
end
