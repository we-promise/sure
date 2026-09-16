require "test_helper"
require "ostruct"

class Provider::AccountData::SnaptradeTest < ActiveSupport::TestCase
  setup do
    @observed_at = Time.utc(2026, 1, 15, 12)
    @client = mock("SnapTrade exact client")
    @adapter = build_adapter
    @account = Ingestion::Record.account(external_id: "account-1", name: "Brokerage", currency: "USD", account_type: "INDIVIDUAL")
    @window = { explicit_start: true, start: "2026-01-01", end: "2026-01-15" }
  end

  test "factory receives application credentials and durable store explicitly and keeps activation disabled" do
    store = Object.new
    transport = mock("transport")
    Provider::Snaptrade::IngestionClient.expects(:new).with(credential_store: store, oauth_client_id: "public-id", oauth_client_secret: "secret").returns(transport)
    adapter = Provider::AccountData::Snaptrade.build(credentials: {}, settings: {}, context: {
      credential_store: store, application_credentials: { oauth_client_id: "public-id", oauth_client_secret: "secret" },
      connection_details: { id: "connection-1" }, timezone: "UTC", observed_at: @observed_at, external_accounts: [], authorizations: []
    })
    assert_instance_of Provider::AccountData::Snaptrade, adapter
    assert_equal %w[holdings activities], adapter.capabilities
    assert_not Provider::AccountData::Snaptrade.native_ready?
    assert_empty Provider::AccountData::Snaptrade.runtime_options
  end

  test "inventory keeps many brokerages under one OAuth connection and secrets out of metadata" do
    adapter = build_adapter(authorizations: [ { id: "internal-auth", external_id: "auth-1", status: "active" } ])
    first = account_payload(number: "123456789")
    second = account_payload(id: "account-2", brokerage_authorization: { id: "auth-2" }, institution_name: "Second Broker")
    @client.expects(:accounts_snapshot).returns([ first, second ])
    @client.expects(:authorizations_snapshot).returns([ { id: "auth-1", disabled: false }, { id: "auth-2", disabled: false } ])
    page = adapter.list_accounts
    assert page.complete?
    assert_equal %w[account-1 account-2], page.records.map { |record| record[:external_id] }
    assert_equal "internal-auth", page.records.first[:metadata][:authorization_id]
    assert_equal "auth-2", page.records.last[:metadata][:provider_authorization_external_id]
    assert_equal "Second Broker", page.records.last[:metadata][:institution][:name]
    assert_equal "123456789", page.records.first[:sensitive_details][:account_number]
    assert_not_includes page.records.first[:metadata].inspect, "123456789"
    assert_equal [ first, second ], page.evidence["accounts"]
    assert_equal false, page.records.first[:metadata][:balance_provided]
  end

  test "missing currency stays unknown and account category suggestions match direct bank and investment accounts" do
    record = @adapter.normalize_account(account_payload(balance: {}, account_category: "DEPOSIT", raw_type: "Checking"))
    assert_nil record[:currency]
    assert_nil record[:balance]
    assert_equal "Depository", record[:metadata][:suggested_account_type]
    assert_equal "CreditCard", @adapter.normalize_account(account_payload(account_category: "LOC", raw_type: "credit-card"))[:metadata][:suggested_account_type]
    assert_equal "Loan", @adapter.normalize_account(account_payload(account_category: "LOC", raw_type: "credit line"))[:metadata][:suggested_account_type]
    assert_equal "Crypto", @adapter.normalize_account(account_payload(account_category: "OTHER", raw_type: "digital asset"))[:metadata][:suggested_account_type]
  end

  test "partial authorization inventory and malformed account retain healthy records without implying absence" do
    @client.expects(:accounts_snapshot).returns([ account_payload, { id: nil } ])
    @client.expects(:authorizations_snapshot).raises(Provider::Snaptrade::ApiError, "unavailable")
    page = @adapter.list_accounts
    assert_not page.complete?
    assert_equal "account-1", page.records.sole[:external_id]
    assert_equal false, page.coverage["absence_authoritative"]
    assert_equal %w[authorization_inventory_unavailable invalid_account], page.warnings.map { |value| value["code"] }
  end

  test "disabled brokerage observations cannot become fresh balances" do
    @client.expects(:accounts_snapshot).returns([ account_payload ])
    @client.expects(:authorizations_snapshot).returns([ { id: "auth-1", disabled: true } ])
    inventory = @adapter.list_accounts
    assert_not inventory.complete?
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_balance(account: inventory.records.sole) }
  end

  test "cash equivalent positions are subtracted once and total uses fresh positions plus adjusted cash" do
    positions = [ position(units: "10", price: "10", cash_equivalent: true), position(instrument: { symbol: "AAPL" }, units: "2", price: "50") ]
    stub_snapshot(positions: positions, balances: [ cash("USD", "150") ])
    page = @adapter.fetch_balance(account: @account)
    record = page.records.sole
    assert page.complete?
    assert_equal BigDecimal("50"), record[:cash_balance]
    assert_equal BigDecimal("250"), record[:balance]
    assert_equal true, record[:metadata].with_indifferent_access[:balance_policy][:current_anchor]
    assert_equal positions, page.evidence["positions"][:results]
    assert_equal positions.map(&:with_indifferent_access), record[:sensitive_details].with_indifferent_access[:snaptrade_snapshot][:positions]
    assert_not_includes record[:metadata].inspect, "units"
    restored = Ingestion::Codec.load(Ingestion::Codec.dump(page))
    assert_equal record[:balance], restored.records.sole[:balance]
    assert_equal BigDecimal("50"), restored.records.sole[:cash_balance]
    assert_equal "10", restored.evidence.fetch("positions").with_indifferent_access.fetch(:results).first.with_indifferent_access[:units]
  end

  test "multi currency positions retain API total and nonprimary cash holdings remove their own sweep overlap" do
    positions = [ position(instrument: { symbol: "EURFUND", currency: "EUR" }, units: "20", price: "1", cash_equivalent: true) ]
    stub_snapshot(positions: positions, balances: [ cash("USD", "50"), cash("EUR", "100") ], account: account_payload(balance: { total: { amount: "900", currency: "USD" } }))
    balance = @adapter.fetch_balance(account: @account)
    assert_equal BigDecimal("900"), balance.records.sole[:balance]
    assert_equal BigDecimal("50"), balance.records.sole[:cash_balance]
    holdings = @adapter.fetch_holdings(account: @account)
    assert holdings.complete?
    synthetic = holdings.records.find { |record| record[:external_id] == "snaptrade_cash_eur" }
    assert_equal BigDecimal("80"), synthetic[:amount]
    assert_equal BigDecimal("80"), synthetic[:quantity]
    assert_equal({ lookup: "account_cash", currency: "EUR" }, synthetic[:security])
    assert_equal false, holdings.coverage["absence_authoritative"]
  end

  test "margin cash remains negative and zero positions use the reported total" do
    stub_snapshot(positions: [], balances: [ cash("USD", "-50") ], account: account_payload(balance: { total: { amount: "0", currency: "USD" } }))
    record = @adapter.fetch_balance(account: @account).records.sole
    assert_equal BigDecimal("-50"), record[:cash_balance]
    assert_equal BigDecimal("0"), record[:balance]
  end

  test "missing responses or mismatched cash denomination keep evidence without posting invented money" do
    foreign_account = Ingestion::Record.account(external_id: "account-1", name: "CAD account", currency: "CAD")
    stub_snapshot(positions: [], balances: [ cash("USD", "100") ], account: account_payload(balance: { total: { amount: "150", currency: "CAD" } }))
    page = @adapter.fetch_balance(account: foreign_account)
    assert_not page.complete?
    assert_nil page.records.sole[:balance]
    assert_nil page.records.sole[:cash_balance]
    assert_equal false, page.records.sole[:metadata].with_indifferent_access[:balance_provided]
    assert_equal [ cash("USD", "100") ], page.evidence["balances"]
  end

  test "a malformed positions envelope cannot replace retained holdings with an empty snapshot" do
    @client.expects(:account_snapshot).with(account_id: "account-1").returns(account_payload)
    @client.expects(:balances_snapshot).with(account_id: "account-1").returns([ cash("USD", "100") ])
    @client.expects(:positions_snapshot).with(account_id: "account-1").returns({})
    page = @adapter.fetch_holdings(account: @account)
    assert_not page.complete?
    assert_empty page.records
    assert_equal({}, page.evidence["positions"])
  end

  test "modern and retained legacy positions keep security date currency identity and per share cost basis" do
    modern = position(instrument: { symbol: " aapl ", description: "APPLE INC", exchange: { mic_code: "XNAS" }, currency: { code: "USD" } },
      units: "1.123456789012345678", price: "50.125", average_purchase_price: "40.25")
    legacy = modern.except(:instrument).merge(symbol: { symbol: modern[:instrument] })
    first, second = [ modern, legacy ].map { |raw| @adapter.normalize_holding(raw, account: @account) }
    assert_equal first.attributes, second.attributes
    assert_equal "security_date_currency", first[:metadata][:holding_identity]
    assert_equal BigDecimal("40.25"), first[:metadata][:cost_basis]
    assert_equal "AAPL", first[:security][:ticker]
    assert_equal "Apple Inc", first[:security][:name]
    assert_equal "XNAS", first[:security][:exchange_mic]
    assert_equal "US", first[:security][:country_code]
    assert_equal "ticker_only", first[:security][:lookup]
    assert first[:security][:repair_malformed_name]
    %w[option future cfd].each do |kind|
      assert_nil @adapter.normalize_holding(position(instrument: { kind: kind, symbol: "AAPL" }), account: @account)
    end
  end

  test "all legacy trade types retain signs labels dates IDs representation and ignored fee behavior" do
    types = %w[BUY SELL REI REINVEST OPTION_BUY OPTION_SELL EXERCISED ASSIGNED]
    rows = types.map { |type| activity(id: type, type: type, units: "2", price: "10", amount: "999", fee: "100") }
    imported = legacy_activities(rows, trades: rows.size, cash: 0)
    rows.each do |raw|
      record = @adapter.normalize_activity(raw, account: @account)
      expected = imported.fetch(raw[:id])
      %i[external_id name date amount currency quantity price].each { |key| assert_equal expected[key], record[key] }
      assert_equal expected[:activity_label], record[:metadata][:investment_activity_label]
      assert_equal "trade", record.ledger_type
      assert_nil record[:metadata][:fee]
      assert_nil record[:metadata][:update_policy]
    end
  end

  test "all cash types including corporate actions and unknown types retain legacy cash representation and signs" do
    types = %w[DIVIDEND DIV CONTRIBUTION WITHDRAWAL TRANSFER_IN TRANSFER_OUT TRANSFER INTEREST FEE TAX CASH STOCK_DIVIDEND SPLIT SPLIT_REVERSE MERGER SPIN_OFF JOURNAL CORP_ACTION OTHER EXPIRED UNKNOWN]
    rows = types.map { |type| activity(id: type, type: type, amount: "25.25") }
    imported = legacy_activities(rows, trades: 0, cash: rows.size)
    rows.each do |raw|
      record = @adapter.normalize_activity(raw, account: @account)
      expected = imported.fetch(raw[:id])
      %i[external_id name date amount currency].each { |key| assert_equal expected[key], record[key] }
      assert_equal expected[:investment_activity_label], record[:metadata][:investment_activity_label]
      assert_equal "transaction", record.ledger_type
    end
    assert_equal BigDecimal("25.25"), @adapter.normalize_activity(activity(type: "TRANSFER", amount: "-25.25"), account: @account)[:amount]
  end

  test "zero quantity trades survive but cash zero and missing price match legacy skips" do
    record = @adapter.normalize_activity(activity(units: "0", price: "10"), account: @account)
    assert_equal BigDecimal("0"), record[:quantity]
    assert_equal true, record[:metadata][:allow_zero_quantity]
    assert_nil @adapter.normalize_activity(activity(type: "DIV", amount: "0"), account: @account)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(activity(price: nil, amount: "100"), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(activity(id: nil), account: @account) }
  end

  test "legacy activity dates use calendar settlement date before trade date and frozen today fallback" do
    adapter = build_adapter(timezone: "America/Los_Angeles")
    record = adapter.normalize_activity(activity(settlement_date: "2026-01-15T00:30:00Z", trade_date: "2026-01-14"), account: @account)
    assert_equal Date.new(2026, 1, 15), record[:date]
    assert_equal Date.new(2026, 1, 12), adapter.normalize_activity(activity(settlement_date: "bad", trade_date: "2026-01-12"), account: @account)[:date]
    assert_equal Date.new(2026, 1, 15), adapter.normalize_activity(activity(settlement_date: nil, trade_date: nil), account: @account)[:date]
  end

  test "live money rejects floats while explicit legacy boundaries preserve cached float values" do
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(activity(price: 1.25), account: @account) }
    assert_equal BigDecimal("2.5"), @adapter.normalize_legacy_activity(activity(price: 1.25, units: 2.0), account: @account)[:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(position(price: 1.25), account: @account) }
    assert_equal BigDecimal("1.25"), @adapter.normalize_legacy_holding(position(price: 1.25), account: @account)[:price]
  end

  test "history pages use fixed windows explicit counts and resume without the generic ninety day floor" do
    rows = 500.times.map { |index| activity(id: "tx-#{index}") }
    @client.expects(:activities_page).with(account_id: "account-1", start_date: "2023-01-16", end_date: "2026-01-15", offset: 0).returns(history(rows, total: 501))
    @client.expects(:activities_page).with(account_id: "account-1", start_date: "2023-01-16", end_date: "2026-01-15", offset: 500).returns(history([ activity(id: "last") ], offset: 500, total: 501))
    first = @adapter.fetch_activities(account: @account, window: { start: "2025-10-15", end: "2026-01-15" })
    second = build_adapter.fetch_activities(account: @account, cursor: first.progress_cursor)
    assert_not first.complete?
    assert_equal first.next_cursor, first.progress_cursor
    assert second.complete?
    assert_equal "last", second.records.sole[:external_id]
    assert_nil second.next_cursor
    assert_equal false, second.coverage["pending_absence_authoritative"]
  end

  test "malformed pagination repeated IDs and other account activities prevent coverage while retaining evidence" do
    @client.expects(:activities_page).returns(history([ activity, activity ], total: 2))
    duplicate = @adapter.fetch_activities(account: @account, window: @window)
    assert_not duplicate.complete?
    assert_includes duplicate.warnings.map { |row| row["code"] }, "repeated_history_rows"
    @client.expects(:activities_page).returns(history([ activity(account: { id: "other" }) ], total: 1))
    foreign = @adapter.fetch_activities(account: @account, window: @window)
    assert_not foreign.complete?
    assert_empty foreign.records
    assert_equal "other", foreign.evidence["response"][:data].sole[:account][:id]
    @client.expects(:activities_page).returns({ data: [ activity ] })
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @account, window: @window) }
  end

  test "sparse long history fallback retains additional rows but cannot claim completeness from an array" do
    @client.expects(:activities_page).returns(history([ activity ], total: 1))
    @client.expects(:activities_fallback_snapshot).with(account_id: "account-1", start_date: "2023-01-16", end_date: "2026-01-15").returns([ activity, activity(id: "older") ])
    page = @adapter.fetch_activities(account: @account)
    assert_not page.complete?
    assert_equal %w[activity-1 older], page.records.map { |record| record[:external_id] }
    assert_includes page.warnings.map { |row| row["code"] }, "fallback_completeness_unknown"
    assert_nil page.next_cursor
  end

  test "empty initial history requires a readiness observation and cannot masquerade as fully indexed" do
    @client.expects(:activities_page).returns(history([], total: 0))
    page = @adapter.fetch_activities(account: @account, window: @window)
    assert_not page.complete?
    assert_empty page.records
    assert_equal "empty_history_requires_readiness", page.warnings.sole["code"]
  end

  test "history cursor is bound to connection account and scope and bounded budgets preserve resumable progress" do
    # Explicit pages avoid a test double that recreates implementation logic.
    20.times do |page|
      rows = 500.times.map { |index| activity(id: "#{page}-#{index}") }
      @client.expects(:activities_page).with(account_id: "account-1", start_date: "2026-01-01", end_date: "2026-01-15", offset: page * 500)
        .returns(history(rows, offset: page * 500, total: 10_001))
    end
    cursor = nil
    20.times { cursor = @adapter.fetch_activities(account: @account, cursor: cursor, window: @window).progress_cursor }
    assert cursor.present?
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_activities(account: @account, cursor: cursor) }
    changed = Ingestion::Record.account(external_id: "other", name: "Other", currency: "USD")
    assert_raises(Provider::AccountData::InvalidResponse) { build_adapter.fetch_activities(account: changed, cursor: cursor) }
    assert_raises(Provider::AccountData::InvalidResponse) { build_adapter(connection_id: "other").fetch_activities(account: @account, cursor: cursor) }
  end

  private
    def build_adapter(**options)
      Provider::AccountData::Snaptrade.new(client: @client, timezone: "UTC", observed_at: @observed_at,
        connection_id: "connection-1", **options)
    end

    def account_payload(**options)
      { id: "account-1", name: "Brokerage", brokerage_authorization: "auth-1", institution_name: "First Broker",
        meta: { type: "INDIVIDUAL" }, balance: { total: { amount: "999", currency: "USD" } } }.merge(options)
    end

    def position(**options)
      { instrument: { symbol: "SPAXX", currency: "USD" }, units: "1", price: "1" }.merge(options)
    end

    def cash(code, amount)
      { currency: { code: code }, cash: amount }
    end

    def activity(**options)
      { id: "activity-1", type: "BUY", symbol: { symbol: "AAPL", description: "Apple", currency: "USD" },
        units: "2", price: "10", amount: "20", currency: "USD", settlement_date: "2026-01-14" }.merge(options)
    end

    def history(rows, offset: 0, total: rows.size)
      { data: rows, pagination: { offset: offset, limit: 500, total: total } }
    end

    def stub_snapshot(positions:, balances:, account: account_payload)
      @client.expects(:account_snapshot).with(account_id: "account-1").once.returns(account)
      @client.expects(:balances_snapshot).with(account_id: "account-1").once.returns(balances)
      @client.expects(:positions_snapshot).with(account_id: "account-1").once.returns({ results: positions })
    end

    def legacy_activities(rows, trades:, cash:)
      linked = OpenStruct.new(currency: "USD")
      legacy = OpenStruct.new(current_account: linked, raw_activities_payload: rows)
      importer = mock("legacy financial boundary")
      Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
      imported = {}
      if trades.positive?
        importer.expects(:import_trade).times(trades).with { |**values| imported[values.fetch(:external_id)] = values }.returns(:entry)
      end
      if cash.positive?
        importer.expects(:import_transaction).times(cash).with { |**values| imported[values.fetch(:external_id)] = values }.returns(:entry)
      end
      processor = SnaptradeAccount::ActivitiesProcessor.new(legacy)
      processor.stubs(:resolve_security).returns(OpenStruct.new(ticker: "AAPL"))
      processor.process
      imported
    end
end
