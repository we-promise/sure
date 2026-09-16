require "test_helper"
require "ostruct"

class Provider::AccountData::MercuryTest < ActiveSupport::TestCase
  setup do
    @client = mock("Mercury transport")
    @adapter = Provider::AccountData::Mercury.new(client: @client, timezone: "America/Los_Angeles")
    @account = Ingestion::Record.account(external_id: "mercury-account", name: "Checking", currency: "USD")
  end

  test "valid transactions preserve legacy ledger arguments and merchant identity" do
    raw = transaction(counterpartyNickname: "Preferred name", counterpartyName: "  ACME INC  ", note: "Invoice", details: "January", kind: "externalTransfer", counterpartyId: "counterparty-1")
    linked = OpenStruct.new(family: OpenStruct.new(timezone: "America/Los_Angeles"))
    legacy = OpenStruct.new(current_account: linked, id: "legacy-account", account_id: @account[:external_id])
    # This example compares normalization arguments; real admission has its own
    # nontransactional suite with persisted sources and competing sessions.
    MercuryItem::LegacyAccess.expects(:with_account).with(legacy).yields(legacy)
    MercuryItem::LegacyAccess.expects(:with_publication).with(legacy, expected_account: linked).yields(legacy, linked)
    importer = mock("ledger importer")
    merchant = OpenStruct.new(name: "ACME INC")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(
      provider_merchant_id: "mercury_merchant_#{Digest::MD5.hexdigest('acme inc')}", name: "ACME INC", source: "mercury"
    ).returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)

    assert_equal :entry, MercuryEntry::Processor.new(raw, mercury_account: legacy).process
    normalized = @adapter.normalize_transaction(raw, account: @account)
    %i[external_id name amount currency date].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal imported[:extra], normalized[:metadata][:extra]
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
  end

  test "outflow signs and decimals stay exact" do
    expense = @adapter.normalize_transaction(transaction(amount: "-0.123456789012345678"), account: @account)
    income = @adapter.normalize_transaction(transaction(amount: "1200.00"), account: @account)

    assert_equal BigDecimal("0.123456789012345678"), expense[:amount]
    assert_equal BigDecimal("-1200"), income[:amount]
    assert_equal "USD", expense[:currency]
  end

  test "legacy normalization explicitly preserves stored float values without weakening native parsing" do
    raw = transaction(amount: -12.34)
    record = @adapter.normalize_legacy_transaction(raw, account: @account)
    assert_equal BigDecimal("12.34"), record[:amount]
    assert_instance_of Float, raw[:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
    snapshot = account_snapshot(currentBalance: 123.45, availableBalance: 100.0)
    assert_equal BigDecimal("123.45"), @adapter.normalize_legacy_account(snapshot)[:balance]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_legacy_transaction(transaction(amount: Float::NAN), account: @account) }
  end

  test "pending to posted retains the external ID and clears pending metadata" do
    pending = @adapter.normalize_transaction(transaction(status: "pending", postedAt: nil), account: @account)
    posted = @adapter.normalize_transaction(transaction(status: "sent"), account: @account)

    assert_equal "mercury_tx-1", pending[:external_id]
    assert_equal pending[:external_id], posted[:external_id]
    assert pending[:pending]
    assert_equal false, posted[:pending]
    assert_equal false, posted[:metadata][:extra]["mercury"]["pending"]
  end

  test "failed transactions are excluded without changing other legacy status handling" do
    assert_nil @adapter.normalize_transaction(transaction(status: "failed"), account: @account)
    %w[sent cancelled reversed blocked].each do |status|
      record = @adapter.normalize_transaction(transaction(status: status), account: @account)
      assert_equal false, record[:pending]
    end
  end

  test "dates prefer posting and preserve family date across midnight" do
    assert_equal Date.new(2026, 1, 1), @adapter.normalize_transaction(transaction(postedAt: "2026-01-02T01:00:00Z"), account: @account)[:date]
    assert_equal Date.new(2026, 1, 2), @adapter.normalize_transaction(transaction(postedAt: "2026-01-02"), account: @account)[:date]
    assert_equal Date.new(2026, 1, 1), @adapter.normalize_transaction(transaction(postedAt: nil, createdAt: "2026-01-02T01:00:00Z"), account: @account)[:date]
  end

  test "name and notes fallbacks do not invent a merchant" do
    record = @adapter.normalize_transaction(transaction(counterpartyName: nil, bankDescription: "Bank description", note: nil, details: nil), account: @account)
    assert_equal "Bank description", record[:name]
    assert_nil record[:metadata][:merchant]
    assert_nil record[:metadata][:notes]
    assert_equal "Unknown transaction", @adapter.normalize_transaction(transaction(counterpartyName: nil, bankDescription: nil), account: @account)[:name]
  end

  test "account balances and liability policy preserve the legacy contract" do
    record = @adapter.normalize_account(account_snapshot)

    assert_equal "mercury-account", record[:external_id]
    assert_equal "Operating", record[:name]
    assert_equal "USD", record[:currency]
    assert_equal BigDecimal("123.456789012345678"), record[:balance]
    assert_equal record[:balance], record[:cash_balance]
    assert_equal BigDecimal("100"), record[:available_balance]
    assert_equal({ debt_transform: "negate", debt_types: [ "CreditCard", "Loan" ], cash_balance: "balance" }, record[:metadata][:balance_policy])
  end

  test "account identifiers are separated into encrypted storage attributes" do
    record = @adapter.normalize_account(account_snapshot(accountNumber: "private-account-number", routingNumber: "private-routing-number", legalBusinessName: "Private business name"))

    assert_equal "private-account-number", record[:sensitive_details][:account_number]
    assert_equal "Private business name", record[:sensitive_details][:legal_business_name]
    refute_includes record[:metadata].inspect, "private-account-number"
    refute_includes record.inspect, "private-account-number"
    assert_raises(FrozenError) { record[:sensitive_details][:account_number].replace("changed") }
    assert_raises(ArgumentError) do
      Ingestion::Record.account(external_id: "id", name: "Name", currency: "USD", sensitive_details: [])
    end
  end

  test "account pagination does not turn an intermediate page into a complete inventory" do
    @client.expects(:get_accounts_page).with(cursor: "first").returns(items: [ account_snapshot ], next_cursor: "second")
    page = @adapter.list_accounts(cursor: "first")

    refute page.complete?
    assert_equal "second", page.next_cursor
    assert_equal "snapshot", page.mode
  end

  test "transaction fetch preserves requested boundaries and excludes failed records explicitly" do
    window = { "start" => "2026-01-01T00:00:00Z", "end" => "2026-02-01T00:00:00Z" }
    @client.expects(:get_account_transactions_page).with("mercury-account", cursor: "1000", start_date: window["start"], end_date: window["end"])
      .returns(items: [ transaction, transaction(id: "failed", status: "failed") ], next_cursor: nil)
    page = @adapter.fetch_transactions(account: @account, cursor: "1000", window: window)

    assert page.complete?
    assert_equal "delta", page.mode
    assert_equal window["end"], page.coverage["end"]
    assert_equal [ "mercury_tx-1" ], page.records.map { |record| record[:external_id] }
    assert_equal [ { "code" => "failed_transactions_excluded", "count" => 1 } ], page.warnings
    assert_equal [ "tx-1", "failed" ], page.evidence["response"][:transactions].map { |raw| raw[:id] }
  end

  test "missing or malformed money and dates fail without exposing private values" do
    invalid = [ transaction(amount: nil), transaction(amount: 0.25), transaction(amount: "NaN"), transaction(id: nil),
      transaction(accountId: "other-account"), transaction(postedAt: "private-invalid-date"), transaction(postedAt: "2026-02-30T00:00:00Z") ]
    invalid.each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
      assert_equal "Invalid Mercury transaction", error.message
      assert_nil error.cause
    end
    [ nil, "invalid", Float::INFINITY ].each do |balance|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(account_snapshot(currentBalance: balance)) }
    end
  end

  test "empty snapshots require a valid collection envelope" do
    @client.expects(:get_accounts_page).with(cursor: nil).returns(items: [], next_cursor: nil)
    assert @adapter.list_accounts.complete?
    [ {}, { items: [], next_cursor: "" }, { items: nil, next_cursor: nil } ].each do |result|
      @client.expects(:get_accounts_page).with(cursor: nil).returns(result)
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.list_accounts }
    end
  end

  test "builder uses only the provided connection credentials settings and timezone" do
    Provider::Mercury.expects(:new).with("private-token", base_url: "https://api-sandbox.mercury.com/api/v1").returns(@client)
    adapter = Provider::AccountData::Mercury.build(
      credentials: { "token" => "private-token" }, settings: { "base_url" => "https://api-sandbox.mercury.com/api/v1" }, context: { timezone: "UTC" }
    )
    assert_instance_of Provider::AccountData::Mercury, adapter
    refute_includes adapter.inspect, "private-token"
  end

  private
    def transaction(**overrides)
      {
        id: "tx-1", accountId: "mercury-account", amount: "-12.34", status: "sent", counterpartyName: "Acme",
        createdAt: "2026-01-01T09:00:00Z", postedAt: "2026-01-02T09:00:00Z"
      }.merge(overrides)
    end

    def account_snapshot(**overrides)
      {
        id: "mercury-account", nickname: "Operating", name: "Checking", currentBalance: "123.456789012345678",
        availableBalance: "100.00", status: "active", type: "checking", kind: "mercury"
      }.merge(overrides)
    end
end
