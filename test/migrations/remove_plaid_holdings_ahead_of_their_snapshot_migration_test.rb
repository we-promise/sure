# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261023090000_remove_plaid_holdings_ahead_of_their_snapshot")

# The old Plaid holdings processor dated each row by its own price date, or
# today when it had none. A row it left later than the snapshot the processor
# now writes stays the account's newest provider date, so the readers of
# current holdings see only that stale row until the price dates catch up.
class RemovePlaidHoldingsAheadOfTheirSnapshotMigrationTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @account = @plaid_account.current_account
    @plaid_provider = AccountProvider.create!(account: @account, provider: @plaid_account)
    @plaid_account.reload
    @snapshot_date = Date.current - 1
    @aapl, @msft = securities(:aapl), securities(:msft)
    @payload = [
      { "security_id" => "a", "quantity" => 10, "institution_price" => 50, "iso_currency_code" => "USD",
        "institution_price_as_of" => @snapshot_date.to_s },
      { "security_id" => "b", "quantity" => 5, "institution_price" => 50, "iso_currency_code" => "USD" }
    ]
    @plaid_account.update!(raw_holdings_payload: { "holdings" => @payload })
  end

  # What the old processor wrote for this payload: AAPL on its price date, the
  # undated MSFT on the day of that sync, at the quantity it had then.
  test "a Plaid row the old processor left after the snapshot is removed, so the next sync is current" do
    plaid_row(@aapl, @snapshot_date, 10)
    stale = plaid_row(@msft, Date.current, 9)

    run_migration

    assert_not Holding.exists?(stale.id)
    sync_holdings
    current = @account.current_holdings.to_h { |holding| [ holding.security_id, holding.qty.to_i ] }
    assert_equal({ @aapl.id => 10, @msft.id => 5 }, current)
  end

  test "a Plaid row priced ahead of today is removed" do
    future = plaid_row(@aapl, Date.current + 1, 10)

    run_migration

    assert_not Holding.exists?(future.id)
  end

  test "Plaid rows on or before the snapshot date are kept" do
    on = plaid_row(@aapl, @snapshot_date, 10)
    before = plaid_row(@msft, @snapshot_date - 3, 5)

    run_migration

    assert Holding.exists?(on.id)
    assert Holding.exists?(before.id)
  end

  test "another provider's later row is kept" do
    item = SimplefinItem.create!(family: @account.family, name: "SF", access_url: "https://example.com/access")
    simplefin_account = SimplefinAccount.create!(simplefin_item: item, name: "Broker", account_id: "sf_1",
                                                 currency: "USD", account_type: "investment", current_balance: 0)
    other = AccountProvider.create!(account: @account, provider: simplefin_account)
    later = @account.holdings.create!(security: @msft, date: Date.current, qty: 9, price: 50, amount: 450,
                                      currency: "USD", account_provider_id: other.id)

    run_migration

    assert Holding.exists?(later.id)
  end

  test "a row with no provider is kept" do
    calculated = @account.holdings.create!(security: @msft, date: Date.current, qty: 9, price: 50, amount: 450, currency: "USD")

    run_migration

    assert Holding.exists?(calculated.id)
  end

  # No usable price date in the payload: the processor writes on today, so only
  # rows after today are ahead of it.
  test "with no usable price date, only Plaid rows after today are removed" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [ @payload.second.merge("institution_price_as_of" => "not a date") ] })
    today = plaid_row(@msft, Date.current, 9)
    future = plaid_row(@aapl, Date.current + 2, 10)

    run_migration

    assert Holding.exists?(today.id)
    assert_not Holding.exists?(future.id)
  end

  # The migration reads the snapshot date its own way; it must agree with the
  # processor's, or it would remove rows the processor still writes.
  test "its snapshot date is the processor's" do
    payloads = [
      { "holdings" => @payload },
      { "holdings" => [ { "institution_price_as_of" => (Date.current + 3).to_s }, { "institution_price_as_of" => (Date.current - 5).to_s } ] },
      { "holdings" => [ { "institution_price_as_of" => "garbage" }, { "institution_price_as_of" => "" } ] },
      { "holdings" => [] },
      {}
    ]

    payloads.each do |payload|
      @plaid_account.update!(raw_holdings_payload: payload)
      assert_equal @plaid_account.holdings_snapshot_date,
                   RemovePlaidHoldingsAheadOfTheirSnapshot.snapshot_date(payload), payload.inspect
    end
  end

  # Where Active Record encryption is configured, PlaidAccount encrypts the
  # payload, so a raw read sees ciphertext and no price dates. The migration
  # reads it as the model does.
  test "an encrypted payload is read through encryption" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    write_encrypted_payload("holdings" => @payload)
    plaid_row(@aapl, @snapshot_date, 10)
    stale = plaid_row(@msft, Date.current, 9)

    run_migration

    assert_not Holding.exists?(stale.id)
  end

  # The scan runs in batches; every Plaid account is still reached.
  test "every Plaid account is scanned when the scan is batched" do
    second = PlaidAccount.create!(plaid_item: @plaid_account.plaid_item, plaid_id: "acc_mock_2", plaid_type: "investment",
                                  name: "Second Plaid", currency: "USD", current_balance: 100,
                                  raw_holdings_payload: { "holdings" => @payload })
    second_account = Account.create!(family: @account.family, name: "Second", balance: 100, currency: "USD",
                                     accountable: Investment.new)
    second_provider = AccountProvider.create!(account: second_account, provider: second)
    stale_one = plaid_row(@msft, Date.current, 9)
    stale_two = second_account.holdings.create!(security: @msft, date: Date.current, qty: 9, price: 50, amount: 450,
                                                currency: "USD", account_provider_id: second_provider.id)

    ActiveRecord::Migration.suppress_messages do
      RemovePlaidHoldingsAheadOfTheirSnapshot.new.remove_stale_rows(batch_size: 1)
    end

    assert_not Holding.exists?(stale_one.id)
    assert_not Holding.exists?(stale_two.id)
  end

  test "running it twice removes nothing more" do
    plaid_row(@aapl, @snapshot_date, 10)
    plaid_row(@msft, Date.current, 9)

    run_migration
    assert_no_difference -> { Holding.count } do
      run_migration
    end
  end

  # Balances and the account's history were computed with the removed rows, so
  # an item that lost rows is synced again to rebuild them.
  test "a sync is scheduled for an item whose rows were removed" do
    plaid_row(@msft, Date.current, 9)

    assert_difference -> { @plaid_account.plaid_item.syncs.count }, 1 do
      run_migration
    end
  end

  test "no sync is scheduled when nothing is removed" do
    plaid_row(@aapl, @snapshot_date, 10)

    assert_no_difference -> { Sync.count } do
      run_migration
    end
  end

  test "a sync that cannot be scheduled does not undo the removal" do
    stale = plaid_row(@msft, Date.current, 9)
    PlaidItem.any_instance.stubs(:sync_later).raises(StandardError, "queue unavailable")

    run_migration

    assert_not Holding.exists?(stale.id)
  end

  # Each account's DELETE commits on its own, so its row locks are released
  # as it goes rather than held until the whole scan ends.
  test "it runs outside a single migration transaction" do
    assert RemovePlaidHoldingsAheadOfTheirSnapshot.disable_ddl_transaction
  end

  private
    def plaid_row(security, date, qty)
      @account.holdings.create!(security: security, date: date, qty: qty, price: 50, amount: qty * 50,
                                currency: "USD", account_provider_id: @plaid_provider.id)
    end

    def write_encrypted_payload(payload)
      encrypted = Class.new(ActiveRecord::Base) do
        self.table_name = "plaid_accounts"
        def self.name = "EncryptedPlaidAccountForTest"
        encrypts :raw_holdings_payload
      end
      encrypted.select(:id).find(@plaid_account.id).update!(raw_holdings_payload: payload)

      raw = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT raw_holdings_payload::text FROM plaid_accounts WHERE id = ?", @plaid_account.id ])
      )
      assert_no_match(/institution_price_as_of/, raw, "the payload must be stored encrypted, or this proves nothing")
    end

    def sync_holdings
      resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
      resolver.stubs(:resolve).with(plaid_security_id: "a").returns(OpenStruct.new(security: @aapl))
      resolver.stubs(:resolve).with(plaid_security_id: "b").returns(OpenStruct.new(security: @msft))
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: resolver).process
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RemovePlaidHoldingsAheadOfTheirSnapshot.new.up
      end
    end
end
