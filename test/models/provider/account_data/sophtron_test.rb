require "test_helper"
require "ostruct"

class Provider::AccountData::SophtronTest < ActiveSupport::TestCase
  setup do
    @client = mock("Sophtron exact transport")
    @adapter = build_adapter
    @account = @adapter.normalize_account(account_data)
  end

  test "canonical posting values agree with the legacy processor" do
    raw = { id: "tx-1", amount: "-12.34", date: "2026-09-13", currency: "USD", merchant: "  Cafe  ", description: "Receipt" }
    linked = OpenStruct.new(family: OpenStruct.new(timezone: "America/Los_Angeles"), currency: "USD")
    legacy = OpenStruct.new(current_account: linked, id: "legacy")
    SophtronItem::LegacyAccess.stubs(:with_account).with(legacy, sync: nil, allow_completed: false).yields(legacy, nil)
    importer = mock("legacy ledger boundary")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(provider_merchant_id: "sophtron_merchant_#{Digest::MD5.hexdigest('cafe')}",
      name: "Cafe", source: "sophtron").returns(OpenStruct.new(name: "Cafe"))
    imported = nil
    importer.expects(:import_transaction).with { |**attrs| imported = attrs }.returns(:entry)
    SophtronEntry::Processor.new(raw, sophtron_account: legacy).process
    row = @adapter.normalize_transaction(raw, account: @account)
    %i[external_id amount currency date name].each { |key| assert_equal imported[key], row[key] }
    assert_equal imported[:notes], row[:metadata][:notes]
    assert_equal "insert_only", row[:metadata][:update_policy]
  end

  test "all existing API ID spellings preserve transaction identity" do
    %i[TransactionID TransactionId transaction_id transactionId ID id].each do |key|
      row = @adapter.normalize_transaction(transaction.except(:TransactionID).merge(key => "retained-id"), account: @account)
      assert_equal "sophtron_retained-id", row[:external_id]
    end
  end

  test "precise native numbers signs and family dates are preserved" do
    row = @adapter.normalize_transaction(transaction(Amount: BigDecimal("0.123456789012345678"), TransactionDate: "2026-09-14T01:00:00Z"), account: @account)
    assert_equal BigDecimal("-0.123456789012345678"), row[:amount]
    assert_equal Date.new(2026, 9, 13), row[:date]
  end

  test "historical float conversion is opt in and does not weaken native parsing" do
    raw = transaction(Amount: -1.25)
    assert_equal BigDecimal("1.25"), @adapter.normalize_legacy_transaction(raw, account: @account)[:amount]
    assert_instance_of Float, raw[:Amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
    assert_equal BigDecimal("12.5"), @adapter.normalize_legacy_account(account_data(AccountBalance: 12.5))[:balance]
  end

  test "missing or malformed money does not silently create a zero posting" do
    [ nil, "bad-money", Float::NAN ].each do |amount|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(Amount: amount), account: @account) }
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(account_data(AccountBalance: amount)) }
    end
  end

  test "account and institution ownership cannot be reassigned by the response" do
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(AccountID: "foreign-account"), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(account_data(UserInstitutionID: "foreign-institution")) }
  end

  test "debt convention and account number masking stay explicit" do
    row = @adapter.normalize_account(account_data(AccountBalance: "-123.45", AvailableBalance: "50", AccountNumber: "1111 2222 1234"))
    assert_equal BigDecimal("-123.45"), row[:balance]
    assert_equal "negate", row[:metadata][:balance_policy][:debt_transform]
    assert_equal [ "CreditCard", "Loan" ], row[:metadata][:balance_policy][:debt_types]
    assert_equal "****1234", row[:sensitive_details][:account_number_mask]
    refute_includes row[:metadata].to_s, "1111 2222 1234"
    assert_equal BigDecimal("50"), row[:available_balance]
  end

  test "available balance is a fallback while unsupported currency uses USD" do
    row = @adapter.normalize_account(account_data(AccountBalance: nil, AvailableBalance: "25", Currency: "unsupported"))
    assert_equal BigDecimal("25"), row[:balance]
    assert_equal "USD", row[:currency]
  end

  test "merchant descriptor cleanup retains existing bank fee and payment names" do
    { "INSUFFICIENT FUNDS FEE" => "Bank Fee: Insufficient Funds", "OVERDRAFT PROTECTION" => "Bank Transfer: Overdraft Protection",
      "AUTO PAY WF HOME MTG" => "Wells Fargo Home Mortgage", "PAYDAY LOAN" => "Payday Loan", "Shop POS 01/02" => "Shop" }.each do |description, expected|
      row = @adapter.normalize_transaction(transaction(Description: description), account: @account)
      assert_equal expected, row[:name]
      assert_equal description, row[:metadata][:notes]
    end
  end

  test "status remains posted to match historical ingestion semantics" do
    row = @adapter.normalize_transaction(transaction(Status: "pending"), account: @account)
    assert_equal false, row[:pending]
    assert_nil row[:pending_external_id]
  end

  test "inventory and transaction pages retain original raw evidence" do
    @client.expects(:get_ingestion_accounts).with("institution-1", cursor: nil).returns(items: [ account_data ], next_cursor: nil, evidence: [ account_data ])
    inventory = @adapter.list_accounts
    assert inventory.complete?
    assert_equal [ account_data ], inventory.evidence["response"]
    @client.expects(:get_ingestion_transactions).with("account-1", start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 14), cursor: nil)
      .returns(items: [ transaction ], next_cursor: nil, evidence: [ transaction ])
    page = @adapter.fetch_transactions(account: @account, window: { start: "2026-09-01T07:00:00Z", end: "2026-09-14T12:00:00Z" })
    assert page.complete?
    assert_equal "delta", page.mode
    assert_equal [ transaction ], page.evidence["response"]
    assert_equal false, page.coverage["pending_absence_authoritative"]
  end

  test "initial history uses 120 days and incremental history uses 60 day overlap" do
    today = Date.new(2026, 9, 14)
    @client.expects(:get_ingestion_transactions).with("account-1", start_date: today - 120, end_date: today, cursor: nil)
      .returns(items: [], next_cursor: nil)
    @adapter.fetch_transactions(account: @account, window: { start: "2026-06-16T12:00:00Z", end: "2026-09-14T12:00:00Z", initial: true, explicit_start: false })
    @client.expects(:get_ingestion_transactions).with("account-1", start_date: Date.new(2026, 9, 10) - 60, end_date: today, cursor: nil)
      .returns(items: [], next_cursor: nil)
    @adapter.fetch_transactions(account: @account, window: { start: "2026-09-03T12:00:00Z", end: "2026-09-14T12:00:00Z",
      initial: false, explicit_start: false, checkpoint_covered_through: "2026-09-10T12:00:00Z" })
  end

  test "explicit history requests cannot exceed three years" do
    @client.expects(:get_ingestion_transactions).with("account-1", start_date: Date.new(2023, 9, 14), end_date: Date.new(2026, 9, 14), cursor: nil)
      .returns(items: [], next_cursor: nil)
    @adapter.fetch_transactions(account: @account, window: { start: "2020-01-01T12:00:00Z", end: "2026-09-14T12:00:00Z", explicit_start: true })
  end

  test "manual source accounts cannot be ingested by the automatic workflow" do
    adapter = build_adapter(manual_sync: true)
    account = adapter.normalize_account(account_data)
    assert_equal true, account[:metadata][:sync_policy][:manual]
    assert_raises(Provider::AccountData::UnsupportedCapability) { adapter.fetch_transactions(account: account) }
    assert_raises(Provider::AccountData::UnsupportedCapability) { adapter.fetch_balance(account: account) }
  end

  test "pure factory builds per-family credentials and migrated institution identity" do
    connection = { external_id: nil, metadata: { source_details: Provider::AccountData::MigrationValue.encode({ identity: { user_institution_id: "institution-1" } }) } }
    Provider::Sophtron.expects(:new).with("family-user", "private-key", base_url: Provider::Sophtron::DEFAULT_BASE_URL).returns(@client)
    adapter = Provider::AccountData::Sophtron.build(credentials: { user_id: "family-user", access_key: "private-key" }, settings: {},
      context: { timezone: "UTC", observed_at: Time.utc(2026, 9, 14), connection_details: connection, external_accounts: [] })
    refute Provider::AccountData::Sophtron.native_ready?
    refute_includes adapter.inspect, "private-key"
  end

  private
    def build_adapter(**options)
      Provider::AccountData::Sophtron.new(**{ client: @client, timezone: "America/Los_Angeles", user_institution_id: "institution-1",
        observed_at: Time.utc(2026, 9, 14, 12) }.merge(options))
    end

    def account_data(**attributes)
      { AccountID: "account-1", AccountName: "Checking", AccountBalance: "123.45", Currency: "USD" }.merge(attributes)
    end

    def transaction(**attributes)
      { TransactionID: "tx-1", Amount: "-12.34", TransactionDate: "2026-09-13", Description: "Shop" }.merge(attributes)
    end
end
