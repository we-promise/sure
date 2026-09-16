require "test_helper"
require "ostruct"

class Provider::AccountData::LunchflowTest < ActiveSupport::TestCase
  setup do
    @client = mock("Lunch Flow transport")
    @adapter = Provider::AccountData::Lunchflow.new(client: @client, timezone: "Australia/Sydney",
      observed_at: Time.utc(2026, 1, 31), include_pending: true)
    @account = Ingestion::Record.account(external_id: "lf-account", name: "Everyday", currency: "AUD")
  end

  test "posted transaction normalization preserves legacy ledger arguments and enrichment" do
    raw = transaction(merchant: "  Coffee Shop  ", description: "Morning coffee")
    linked = OpenStruct.new(currency: "AUD", family: OpenStruct.new(timezone: "Australia/Sydney"))
    legacy = OpenStruct.new(current_account: linked)
    importer = mock("legacy ledger boundary")
    merchant = OpenStruct.new(name: "Coffee Shop")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(
      provider_merchant_id: "lunchflow_merchant_#{Digest::MD5.hexdigest('coffee shop')}", name: "Coffee Shop", source: "lunchflow"
    ).returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)

    assert_equal :entry, LunchflowEntry::Processor.new(raw, lunchflow_account: legacy).process
    record = @adapter.normalize_transaction(raw, account: @account)

    %i[external_id name amount currency date].each { |key| assert_equal imported[key], record[key] }
    assert_equal imported[:extra].deep_stringify_keys, record[:metadata][:extra]
    assert_equal imported[:notes], record[:metadata][:notes]
    assert_equal merchant.name, record[:metadata][:merchant][:name]
    assert_equal Date.new(2026, 1, 15), record[:date]
  end

  test "missing inventory currency and balance stay unknown until an independent balance succeeds" do
    raw = account_snapshot.except(:currency)
    inventory = @adapter.normalize_account(raw)

    assert_nil inventory[:currency]
    assert_nil inventory[:balance]
    assert_equal false, inventory[:metadata][:balance_provided]
    assert_equal "Bank - Everyday", inventory[:name]
    assert_equal "quiltt", inventory[:metadata][:downstream_provider]
    refute_equal "quiltt", @adapter.class.definition.key
    record = @adapter.normalize_balance({ balance: { amount: "12.000000000000000001", currency: "eur" } }, account: inventory)
    assert_equal "EUR", record[:currency]
    assert_equal BigDecimal("12.000000000000000001"), record[:balance]
    assert_equal true, record[:metadata][:balance_provided]
    assert_equal "negate", record[:metadata][:balance_policy][:debt_transform]
    assert_equal %w[CreditCard Loan], record[:metadata][:balance_policy][:debt_types]
  end

  test "failed balance never writes zero or replaces currency while another stream can succeed" do
    @client.expects(:get_account_balance_snapshot).with("lf-account").returns(balance: { amount: nil, currency: "USD" })
    @client.expects(:get_account_transactions_snapshot).with("lf-account", start_date: nil, end_date: nil, include_pending: true)
      .returns(transactions: [ transaction ], total: 1)

    balance = @adapter.fetch_balance(account: @account)
    transactions = @adapter.fetch_transactions(account: @account)

    assert_not balance.complete?
    assert_empty balance.records
    assert_nil balance.evidence.fetch("response").fetch(:balance).fetch(:amount)
    assert transactions.complete?
    assert_equal 1, transactions.records.size
    assert_equal "AUD", @adapter.normalize_balance({ balance: { amount: "0" } }, account: @account)[:currency]
    unknown = @adapter.normalize_account(account_snapshot.except(:currency))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_balance({ balance: { amount: "0" } }, account: unknown) }
  end

  test "native money stays exact and historical Float replay is explicit" do
    native = @adapter.normalize_transaction(transaction(amount: BigDecimal("-0.123456789012345678")), account: @account)
    assert_equal BigDecimal("0.123456789012345678"), native[:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(amount: -1.25), account: @account) }
    replay = @adapter.normalize_legacy_transaction(transaction(amount: -1.25), account: @account)
    assert_equal BigDecimal("1.25"), replay[:amount]
    [ nil, "NaN", "Infinity", {}, Float::NAN ].each do |amount|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(amount: amount), account: @account) }
    end
  end

  test "temporary IDs retain legacy JSON number spelling and occurrence multiplicity" do
    old = transaction(id: nil, amount: -50.0, isPending: true)
    expected_hash = Digest::MD5.hexdigest(%i[accountId amount currency date merchant description].map { |key| old[key] }.compact.join("|"))
    native = old.merge(amount: BigDecimal("-50.0"))
    assert_equal "lunchflow_pending_#{expected_hash}", @adapter.normalize_transaction(native, account: @account)[:external_id]
    assert_equal "lunchflow_pending_#{expected_hash}", @adapter.normalize_legacy_transaction(old, account: @account)[:external_id]
    @client.expects(:get_account_transactions_snapshot).returns(transactions: [ native, native.deep_dup ], total: 2)

    page = @adapter.fetch_transactions(account: @account)

    assert_equal 2, page.records.size
    assert_equal [ 0, 1 ], page.records.map { |record| record[:metadata][:identity_occurrence] }
    assert_equal 1, page.records.map { |record| record[:external_id] }.uniq.size
    assert_equal "reuse_pending_or_allocate_suffix", page.records.first[:metadata][:identity_policy]
    assert_equal 8, page.records.first[:metadata][:posted_match_policy][:forward_days]
    assert_equal "lunchflow_pending_", page.records.first[:metadata][:posted_match_policy][:exclude_external_id_prefix]
  end

  test "absent pending metadata remains distinguishable from false and configuration filters pending" do
    absent = @adapter.normalize_transaction(transaction.except(:isPending), account: @account)
    settled = @adapter.normalize_transaction(transaction(isPending: false), account: @account)
    assert_equal({}, absent[:metadata][:extra])
    assert_equal false, absent[:metadata][:pending_provided]
    assert_equal true, settled[:metadata][:pending_provided]
    assert_equal false, settled[:metadata][:extra]["lunchflow"]["pending"]
    disabled = Provider::AccountData::Lunchflow.new(client: @client, timezone: "UTC", observed_at: Date.new(2026, 1, 31), include_pending: false)
    assert_nil disabled.normalize_transaction(transaction(isPending: true), account: @account)
  end

  test "transaction ownership and timestamp validation cannot move data between accounts" do
    [ transaction(accountId: "other-account"), transaction(date: "2026-02-30T12:00:00Z"),
      transaction(date: "2026-01-15T12:00:00"), transaction(date: nil) ].each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
      refute_includes error.message, "other-account"
      assert_nil error.cause
    end
    assert_equal "AUD", @adapter.normalize_transaction(transaction(currency: "XXX"), account: @account)[:currency]
  end

  test "reported totals and unrecognized continuations prevent false completeness" do
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot ], total: 2, nextCursor: "not-yet-supported")
    page = @adapter.list_accounts
    assert_not page.complete?
    assert_nil page.next_cursor
    assert_equal 1, page.records.size
    assert_equal 2, page.evidence.fetch("response").fetch(:total)
    assert_includes page.warnings.map { |value| value.fetch("code") }, "reported_total_mismatch"
    @client.expects(:get_accounts_snapshot).returns(accounts: [], total: 0)
    assert @adapter.list_accounts.complete?
  end

  test "holdings preserve raw nested IDs custom tickers cost basis and linked crypto classification" do
    record = @adapter.normalize_holding(holding(raw: { quiltt: { id: "source-holding" } }), account: @account)
    assert_equal "lunchflow_source-holding", record[:external_id]
    assert_equal BigDecimal("20"), record[:metadata][:cost_basis]
    assert_equal Date.new(2026, 1, 31), record[:date]
    assert_equal false, record[:metadata][:delete_future_holdings]
    custom = @adapter.normalize_holding(holding(security: { name: "Employer Fund" }), account: @account)
    assert_match(/\ACUSTOM:EMPLOYER_FUND_/, custom[:security][:ticker])
    crypto_account = Ingestion::Record.account(**@account.attributes.merge(metadata: { linked_account_type: "Crypto" }))
    crypto = @adapter.normalize_holding(holding(security: { tickerSymbol: "UNI", name: "Uniswap" }), account: crypto_account)
    assert_equal "CRYPTO:UNI", crypto[:security][:ticker]
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_holding(holding(raw: { one: { id: "one" }, two: { id: "two" } }), account: @account)
    end
  end

  test "fallback holding IDs reproduce historical numeric spellings and 501 preserves unsupported state" do
    old = holding(quantity: 2.0, value: 100.0)
    content = [ old[:security][:tickerSymbol], old[:security][:name], old[:quantity], old[:value] ].compact.join("-")
    record = @adapter.normalize_legacy_holding(old, account: @account)
    assert_equal "lunchflow_#{Digest::MD5.hexdigest(content)[0, 12]}", record[:external_id]
    @client.expects(:get_account_holdings_snapshot).with("lf-account").returns(holdings_not_supported: true)
    page = @adapter.fetch_holdings(account: @account)
    assert_not page.complete?
    assert_equal false, page.coverage.fetch("supported")
    assert_equal false, page.coverage.fetch("absence_authoritative")
    assert_not Provider::AccountData::Lunchflow.native_ready?
  end

  private
    def account_snapshot(**attributes)
      { id: "lf-account", name: "Everyday", institution_name: "Bank", institution_logo: "https://bank.example/logo",
        provider: "quiltt", status: "ACTIVE", currency: "AUD" }.merge(attributes)
    end

    def transaction(**attributes)
      { id: "lf-transaction", accountId: "lf-account", amount: "-12.50", currency: "AUD",
        date: "2026-01-14T14:30:00Z", merchant: "Coffee Shop", description: "Coffee", isPending: false }.merge(attributes)
    end

    def holding(**attributes)
      { security: { tickerSymbol: "VTI", name: "Total Market", currency: "USD" },
        quantity: "2", price: "50", value: "100", costBasis: "20", currency: "USD", raw: {} }.merge(attributes)
    end
end
