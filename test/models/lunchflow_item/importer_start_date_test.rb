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

  test "later syncs resume a week before the account's last successful fetch" do
    synced_through = Time.zone.parse("2026-10-10 06:00")
    store_previous_transaction
    @lunchflow_account.update!(transactions_synced_through: synced_through)
    @item.stubs(:last_synced_at).returns(Time.zone.parse("2026-10-20 06:00"))
    expect_fetch_from(synced_through - 7.days)

    import_transactions
  end

  test "accounts without a fetch marker refetch the full history" do
    store_previous_transaction
    @item.stubs(:last_synced_at).returns(Time.zone.parse("2026-10-20 06:00"))
    expect_fetch_from(nil)

    import_transactions
  end

  test "first sync starts at the chosen start date" do
    @item.update!(sync_start_date: Date.new(2026, 1, 15))
    expect_fetch_from(Date.new(2026, 1, 15))

    import_transactions
  end

  test "the chosen start date is the day picked in the family's timezone" do
    @item.family.update!(timezone: "Europe/Berlin")
    Time.use_zone("Europe/Berlin") { @item.update!(sync_start_date: "2026-01-15") }
    expect_fetch_from(Date.new(2026, 1, 15))

    import_transactions
  end

  test "later syncs never go back before the chosen start date" do
    @item.update!(sync_start_date: Date.new(2026, 10, 8))
    store_previous_transaction
    @lunchflow_account.update!(transactions_synced_through: Time.zone.parse("2026-10-10 06:00"))
    expect_fetch_from(Date.new(2026, 10, 8))

    import_transactions
  end

  test "later syncs resume from the last fetch when the chosen start date is older" do
    synced_through = Time.zone.parse("2026-10-10 06:00")
    @item.update!(sync_start_date: Date.new(2026, 1, 15))
    store_previous_transaction
    @lunchflow_account.update!(transactions_synced_through: synced_through)
    expect_fetch_from(synced_through - 7.days)

    import_transactions
  end

  test "a first fetch records how far back it reached" do
    @item.update!(sync_start_date: Date.new(2026, 1, 15))
    expect_fetch_from(Date.new(2026, 1, 15))

    import_transactions

    assert_equal Time.zone.parse("2026-01-15"), @lunchflow_account.reload.history_synced_from
  end

  test "moving the start date earlier fetches from the new date" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))
    mark_previously_synced(history_from: Time.zone.parse("2026-03-01"))
    expect_fetch_from(Date.new(2026, 1, 1))

    import_transactions

    assert_equal Time.zone.parse("2026-01-01"), @lunchflow_account.reload.history_synced_from
  end

  test "clearing the start date fetches the full history" do
    mark_previously_synced(history_from: Time.zone.parse("2026-03-01"))
    expect_fetch_from(nil)

    import_transactions

    assert_nil @lunchflow_account.reload.history_synced_from
  end

  test "a full history fetch marks the account as having everything" do
    @lunchflow_account.update!(history_synced_from: Time.zone.parse("2026-03-01"))
    expect_fetch_from(nil)

    import_transactions

    assert_nil @lunchflow_account.reload.history_synced_from
  end

  test "keeping the same start date doesn't refetch history" do
    @item.update!(sync_start_date: Date.new(2026, 3, 1))
    mark_previously_synced(history_from: Time.zone.parse("2026-03-01"))
    expect_fetch_from(Time.zone.parse("2026-10-03 06:00"))

    import_transactions
  end

  test "moving the start date later keeps the history already fetched" do
    @item.update!(sync_start_date: Date.new(2026, 3, 1))
    mark_previously_synced(history_from: Time.zone.parse("2026-01-01"))
    expect_fetch_from(Time.zone.parse("2026-10-03 06:00"))

    import_transactions

    assert_equal Time.zone.parse("2026-01-01"), @lunchflow_account.reload.history_synced_from
  end

  test "accounts with the full history don't refetch it when a start date is chosen" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))
    mark_previously_synced(history_from: nil)
    expect_fetch_from(Time.zone.parse("2026-10-03 06:00"))

    import_transactions
  end

  test "a failed history fetch keeps the previous history marker" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))
    mark_previously_synced(history_from: Time.zone.parse("2026-03-01"))
    @provider.expects(:get_account_transactions)
      .raises(Provider::Lunchflow::LunchflowError.new("Rate limited", :rate_limited))

    import_transactions

    assert_equal Time.zone.parse("2026-03-01"), @lunchflow_account.reload.history_synced_from
  end

  test "a successful fetch records when it ran" do
    expect_fetch_from(nil)

    travel_to Time.zone.parse("2026-10-28 06:00") do
      import_transactions
    end

    assert_equal Time.zone.parse("2026-10-28 06:00"), @lunchflow_account.reload.transactions_synced_through
  end

  test "a failed fetch keeps the previous marker" do
    synced_through = Time.zone.parse("2026-10-10 06:00")
    @lunchflow_account.update!(transactions_synced_through: synced_through)
    @provider.expects(:get_account_transactions)
      .raises(Provider::Lunchflow::LunchflowError.new("Rate limited", :rate_limited))

    result = import_transactions

    assert_not result[:success]
    assert_equal synced_through, @lunchflow_account.reload.transactions_synced_through
  end

  test "a response without a transaction list keeps the previous marker" do
    synced_through = Time.zone.parse("2026-10-10 06:00")
    @lunchflow_account.update!(transactions_synced_through: synced_through)
    @provider.expects(:get_account_transactions).returns({})

    result = import_transactions

    assert_not result[:success]
    assert_equal synced_through, @lunchflow_account.reload.transactions_synced_through
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

    # An account whose last successful fetch ran on 2026-10-10 06:00.
    def mark_previously_synced(history_from:)
      store_previous_transaction
      @lunchflow_account.update!(
        transactions_synced_through: Time.zone.parse("2026-10-10 06:00"),
        history_synced_from: history_from
      )
    end
end
