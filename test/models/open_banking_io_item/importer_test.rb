require "test_helper"

class OpenBankingIoItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://staging.open-banking.io",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @provider_account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Everyday",
      account_id: "acc_1",
      currency: "EUR"
    )
    @importer = OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: nil)
  end

  def store(txns)
    @importer.send(:store_transactions, @provider_account, transactions: txns)
    @provider_account.reload.raw_transactions_payload.to_a
  end

  # Fix 1: storage must update in place so a pending row that settles to booked
  # under the SAME id replaces the stored pending row instead of being dropped
  # as a duplicate (which would leave the entry stuck pending forever).
  test "a booked transaction reusing a pending transaction id replaces the stored pending row in place" do
    store([ { "id" => "P", "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "10.00", "booking_date" => "2026-01-10" } ])

    stored = store([ { "id" => "P", "status" => "BOOK", "credit_debit_indicator" => "DBIT", "amount" => "12.00", "booking_date" => "2026-01-11" } ])

    assert_equal 1, stored.size
    row = stored.first.with_indifferent_access
    assert_equal "BOOK", row[:status]
    assert_equal "12.00", row[:amount]
    assert_equal "2026-01-11", row[:booking_date]
  end

  # Fix 2: an ISO-20022 transaction that arrives with no `id` must still be stored
  # under a stable content-hash key rather than being silently dropped.
  test "an id-less transaction is stored under a stable content-hash key rather than dropped" do
    txn = { "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "9.99", "booking_date" => "2026-02-01", "creditor_name" => "Spotify", "remittance_information" => "Subscription" }

    stored = store([ txn ])
    assert_equal 1, stored.size

    # Re-storing identical id-less content must not create a duplicate row.
    stored_again = store([ txn.dup ])
    assert_equal 1, stored_again.size
  end

  # Fix 1: the importer must ask open-banking.io to pull fresh upstream data
  # (sync_all) BEFORE it paginates account transactions, otherwise it just
  # re-imports the stale cached window.
  test "triggers an upstream sync_all before fetching transactions" do
    account = Account.create!(family: @family, name: "Everyday", accountable: Depository.new(subtype: "checking"), balance: 100, currency: "EUR")
    AccountProvider.create!(account: account, provider: @provider_account)

    provider = mock("provider")
    seq = sequence("import")
    provider.expects(:sync_all).in_sequence(seq)
    provider.expects(:get_accounts).in_sequence(seq).returns([ { id: "acc_1", currency: "EUR" } ])
    provider.expects(:get_account_transactions).in_sequence(seq).returns([])

    OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: provider).import
  end

  # Fix 1: a sync_all failure must not abort importing the cached data, and it
  # must be surfaced through DebugLogEntry (not just the logger).
  test "a failing upstream sync_all is swallowed, captured, and does not abort the import" do
    provider = mock("provider")
    provider.expects(:sync_all).raises(StandardError.new("session expired"))
    provider.expects(:get_accounts).returns([ { id: "acc_1", currency: "EUR" } ])

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_error").count }, +1 do
      result = OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: provider).import
      assert result[:success]
    end
  end

  # Fix 7: an account that already exists but is not yet linked must have its
  # snapshot (name/currency/balance) refreshed on a subsequent sync, instead of
  # falling through both branches and going stale until a user links it.
  test "refreshes the snapshot of an existing but unlinked account on sync" do
    provider = mock("provider")
    provider.stubs(:sync_all)
    provider.expects(:get_accounts).returns([
      {
        id: "acc_1",
        display_name: "Renamed Everyday",
        currency: "USD",
        balances: [ { type: "ITBD", amount: "500.00", currency: "USD" } ]
      }
    ])

    OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: provider).import

    @provider_account.reload
    assert_equal "Renamed Everyday", @provider_account.name
    assert_equal "USD", @provider_account.currency
    assert_equal BigDecimal("500.00"), @provider_account.current_balance
  end

  # Fix 6: a provider API error while fetching accounts must be captured to
  # DebugLogEntry (surfacing on /settings/debug), not only Rails.logger.
  test "captures a provider account-fetch error to DebugLogEntry" do
    provider = mock("provider")
    provider.stubs(:sync_all)
    provider.expects(:get_accounts).raises(Provider::OpenBankingIo::Error.new("boom", :server_error))

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_error").count }, +1 do
      result = OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: provider).import
      assert_not result[:success]
    end
  end
end
