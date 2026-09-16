require "test_helper"

class Provider::AccountData::QuestradeTest < ActiveSupport::TestCase
  setup do
    @client = mock("Questrade bounded reader")
    @adapter = build_adapter
    @account = @adapter.normalize_account(number: "123", type: "TFSA", status: "Active")
  end

  test "the native factory requires durable session injection and remains gated" do
    context = { timezone: "America/Toronto", observed_at: Time.utc(2026, 9, 14, 12), questrade_retained_credentials: nil }
    assert_raises(Provider::Questrade::ConfigurationError) do
      @adapter.class.build(credentials: { refresh_token: "private-token" }, settings: {}, context: context)
    end
    store = mock("durable credential store")
    store.stubs(:with_session_lock)
    reader = mock("durable reader")
    Provider::Questrade::IngestionClient.expects(:new).with(credential_store: store, environment: "live").returns(reader)
    instance = @adapter.class.build(credentials: { refresh_token: "stale-input" }, settings: {}, context: context.merge(credential_store: store))
    assert_instance_of @adapter.class, instance
    assert_equal [ :credential_store, :questrade_retained_credentials ], @adapter.class.context_sources
    assert_equal [ :questrade_retained_credentials ], @adapter.class.frozen_context_sources
    assert_equal %w[holdings activities], @adapter.capabilities
    assert_equal :account, @adapter.activity_scope
    assert_equal "connection", @adapter.class.definition.credential_scope
    refute @adapter.class.native_ready?
  end

  test "inventory preserves account identity names CAD and private evidence" do
    response = { accounts: [ { number: "123", type: "TFSA", status: "Active" } ], userId: "private-user-id" }
    @client.expects(:get_ingestion_accounts).returns(response)
    page = @adapter.list_accounts
    assert page.complete?
    assert_equal "snapshot", page.mode
    assert_equal "TFSA (123)", page.records.first[:name]
    assert_equal "CAD", page.records.first[:currency]
    assert_equal "123", page.records.first[:sensitive_details][:account_number]
    assert_nil page.records.first[:balance]
    assert_equal response, page.evidence["response"]
    refute_includes page.records.first[:metadata].to_s, "private-user-id"
  end

  test "home currency follows absolute cash then equity and preserves negative margin cash" do
    response = balances(per: [ { currency: "CAD", cash: "5", totalEquity: "500" }, { currency: "USD", cash: "-20", totalEquity: "100" } ],
      combined: [ { currency: "CAD", totalEquity: "800" }, { currency: "USD", totalEquity: "123.4567890123456789" } ])
    @client.expects(:get_ingestion_balances).with(account_id: "123").returns(response)
    page = @adapter.fetch_balance(account: @account)
    record = page.records.first
    assert_equal "USD", record[:currency]
    assert_equal BigDecimal("-20"), record[:cash_balance]
    assert_equal BigDecimal("123.4567890123456789"), record[:balance]
    assert_equal true, record[:metadata].with_indifferent_access.dig(:balance_policy, :current_anchor)
    assert_equal "preserve", record[:metadata].with_indifferent_access.dig(:balance_policy, :debt_transform)
    assert_equal response, page.evidence["response"]
  end

  test "equal cash selects greatest absolute equity without Float rounding" do
    response = balances(per: [ { currency: "CAD", cash: "0", totalEquity: "1.00000000000000001" },
      { currency: "USD", cash: "0", totalEquity: "1.00000000000000002" } ], combined: [ { currency: "USD", totalEquity: "10" } ])
    @client.expects(:get_ingestion_balances).returns(response)
    assert_equal "USD", @adapter.fetch_balance(account: @account).records.first[:currency]
  end

  test "missing combined equity cannot manufacture a zero portfolio valuation" do
    @client.expects(:get_ingestion_balances).returns(balances(per: [], combined: []))
    page = @adapter.fetch_balance(account: @account)
    assert_nil page.records.first[:balance]
    assert_equal "combined_balance_unavailable", page.warnings.first["code"]
    @client.expects(:get_ingestion_balances).returns(perCurrencyBalances: [])
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @account) }
  end

  test "positions gain symbol currency and exact legacy holding identity and cost basis" do
    raw = holding(currency: nil)
    @client.expects(:get_ingestion_holdings).with(account_id: "123").returns(positions: [ raw ])
    symbols = { symbols: [ { symbolId: 456, currency: "USD" } ] }
    @client.expects(:get_ingestion_symbols).with(ids: [ 456 ]).returns(symbols)
    @client.expects(:get_ingestion_balances).returns(balances)
    page = @adapter.fetch_holdings(account: @account)
    record = page.records.first
    assert_equal "questrade_123_456_2026-09-14", record[:external_id]
    assert_equal "USD", record[:currency]
    assert_equal BigDecimal("12.34567890123456789"), record[:price]
    assert_equal BigDecimal("24.69135780246913578"), record[:amount]
    assert_equal BigDecimal("8.75"), record[:metadata][:cost_basis]
    assert_equal "ticker_only", record[:security][:lookup]
    assert_equal [ symbols ], page.evidence["symbols"]
    assert_equal "delta", page.mode
    assert_equal false, page.coverage["absence_authoritative"]
  end

  test "an empty balance response retains captured cash and total without inventing new values" do
    account = Ingestion::Record.account(**@account.attributes.merge(balance: BigDecimal("500"), cash_balance: BigDecimal("-20")))
    @client.expects(:get_ingestion_balances).returns(balances(per: [], combined: []))
    page = @adapter.fetch_balance(account: account)
    assert_equal BigDecimal("500"), page.records.first[:balance]
    assert_equal BigDecimal("-20"), page.records.first[:cash_balance]
    assert_equal BigDecimal("500"), page.evidence["fallback_balance"]
    assert_equal BigDecimal("-20"), page.evidence["fallback_cash"]
  end

  test "a missing combined balance cannot relabel a cached total into another currency" do
    account = Ingestion::Record.account(**@account.attributes.merge(balance: BigDecimal("500"), cash_balance: BigDecimal("10")))
    @client.expects(:get_ingestion_balances).returns(balances(per: [ { currency: "USD", cash: "20" } ], combined: []))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: account) }
  end

  test "foreign cash uses account-scoped cash securities preserving daily IDs and threshold" do
    @client.expects(:get_ingestion_holdings).returns(positions: [])
    @client.expects(:get_ingestion_symbols).never
    @client.expects(:get_ingestion_balances).returns(balances(per: [ { currency: "CAD", cash: "200", totalEquity: "500" },
      { currency: "USD", cash: "-10", totalEquity: "50" }, { currency: "EUR", cash: "0.009", totalEquity: "0.009" } ]))
    page = @adapter.fetch_holdings(account: @account)
    assert_equal 1, page.records.size
    record = page.records.first
    assert_equal "questrade_cash_usd_2026-09-14", record[:external_id]
    assert_equal({ lookup: "account_cash", currency: "USD" }, record[:security])
    assert_equal BigDecimal("-10"), record[:amount]
    assert_equal BigDecimal("-10"), record[:quantity]
    assert_equal BigDecimal("1"), record[:price]
  end

  test "short securities positions retain signed quantity instead of converting debt into assets" do
    record = @adapter.normalize_holding(holding(openQuantity: "-2", currentMarketValue: "-25"), account: @account)
    assert_equal BigDecimal("-2"), record[:quantity]
    assert_equal BigDecimal("-25"), record[:amount]
  end

  test "holdings reject foreign account rows and inexact native decimals" do
    [ holding(accountNumber: "999"), holding(currentPrice: 0.1), holding(currentPrice: "bad") ].each do |raw|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(raw, account: @account) }
    end
    assert_nil @adapter.normalize_holding(holding(openQuantity: "0"), account: @account)
  end

  test "legacy holding Float conversion is explicit and limited to monetary fields" do
    record = @adapter.normalize_legacy_holding(holding(currentPrice: 0.1, openQuantity: 2.0, averageEntryPrice: 0.05), account: @account)
    assert_equal BigDecimal("0.1"), record[:price]
    assert_equal BigDecimal("0.2"), record[:amount]
    assert_equal BigDecimal("0.05"), record[:metadata][:cost_basis]
  end

  test "trade and commission retain separate exact legacy identities signs and dates" do
    raw = activity(type: "Trades", action: "Sell", quantity: "2", price: "10.25", commission: "-0.50", netAmount: "20")
    records = @adapter.normalize_activity(raw, account: @account)
    assert_equal 2, records.size
    trade, fee = records
    digest = legacy_digest(raw)
    assert_equal "questrade_trade_#{digest}", trade[:external_id]
    assert_equal "questrade_fee_#{digest}", fee[:external_id]
    assert_equal "sell", trade[:activity_type]
    assert_equal BigDecimal("-2"), trade[:quantity]
    assert_equal BigDecimal("-20.50"), trade[:amount]
    assert_equal BigDecimal("0.50"), fee[:amount]
    assert_equal "Commission for VFV.TO", fee[:name]
    assert_equal Date.new(2026, 9, 10), trade[:date]
    assert_equal trade[:date], fee[:date]
  end

  test "cash activity direction follows net amount with settlement date and optional security" do
    { "Deposits" => "contribution", "Withdrawals" => "withdrawal", "Dividends" => "dividend",
      "Interest" => "interest", "Fees and rebates" => "fee" }.each do |type, expected|
      raw = activity(type: type, netAmount: "12.75")
      record = @adapter.normalize_activity(raw, account: @account).sole
      assert_equal expected, record[:activity_type]
      assert_equal BigDecimal("-12.75"), record[:amount]
      assert_equal Date.new(2026, 9, 12), record[:date]
      assert_equal "VFV.TO", record[:security][:ticker]
      assert_equal "questrade_cash_#{legacy_digest(raw)}", record[:external_id]
    end
  end

  test "Norberts Gambit journals preserve zero-cash signed security movement and Transfer label" do
    %w[Other Transfers].each do |type|
      raw = activity(type: type, quantity: "-3", netAmount: "0")
      record = @adapter.normalize_activity(raw, account: @account).sole
      assert_equal "questrade_journal_#{legacy_digest(raw)}", record[:external_id]
      assert_equal BigDecimal("-3"), record[:quantity]
      assert_equal BigDecimal("0"), record[:amount]
      assert_equal BigDecimal("0"), record[:price]
      assert_equal "Transfer", record[:metadata][:investment_activity_label]
    end
  end

  test "unsupported FX conversions and corporate actions stay evidence-only" do
    [ "FX conversion", "Corporate actions", "Unrecognized", "" ].each do |type|
      assert_empty @adapter.normalize_activity(activity(type: type), account: @account)
    end
    assert_empty @adapter.normalize_activity(activity(type: "Transfers", symbol: ""), account: @account)
  end

  test "native activities reject monetary Float while legacy IDs hash the original representation" do
    raw = activity(type: "Trades", quantity: 2.0, price: 0.1, netAmount: -0.2)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @account) }
    record = @adapter.normalize_legacy_activity(raw, account: @account).sole
    assert_equal "questrade_trade_#{legacy_digest(raw)}", record[:external_id]
    assert_equal BigDecimal("0.2"), record[:amount]
  end

  test "exact JSON decimals retain legacy activity IDs without rounding financial values" do
    [ [ "0.0000001", "-0.0000001234567890123456789" ],
      [ "1234567890123456789.125", "-1234567890123456789.875" ] ].each do |quantity, net|
      json = numeric_activity_json(quantity: quantity, net: net)
      legacy = JSON.parse(json, symbolize_names: true)
      exact = JSON.parse(json, symbolize_names: true, decimal_class: BigDecimal)
      records = @adapter.normalize_activity(exact, account: @account)

      assert_equal [ "questrade_trade_#{legacy_digest(legacy)}", "questrade_fee_#{legacy_digest(legacy)}" ],
        records.map { |record| record[:external_id] }
      assert_equal @adapter.normalize_legacy_activity(legacy, account: @account).map { |record| record[:external_id] },
        records.map { |record| record[:external_id] }
      assert_equal BigDecimal(quantity), records.first[:quantity]
      assert_equal BigDecimal("1.234567890123456789"), records.first[:price]
      assert_equal BigDecimal(quantity) * BigDecimal("1.234567890123456789"), records.first[:amount]
      assert_equal BigDecimal("0.01234567890123456789"), records.last[:amount]
      assert_instance_of BigDecimal, exact[:quantity]
      assert_equal BigDecimal(quantity), exact[:quantity]
    end
  end

  test "activity identity retains JSON integer decimal and string distinctions" do
    identities = [ "2", "2.0", '"2e0"' ].map do |quantity|
      json = numeric_activity_json(quantity: quantity, net: "-2.0")
      legacy = JSON.parse(json, symbolize_names: true)
      exact = JSON.parse(json, symbolize_names: true, decimal_class: BigDecimal)
      record = @adapter.normalize_activity(exact, account: @account).first
      assert_equal "questrade_trade_#{legacy_digest(legacy)}", record[:external_id]
      assert_equal BigDecimal("2"), record[:quantity]
      record[:external_id]
    end
    assert_equal 3, identities.uniq.size
  end

  test "legacy typed decimal inputs hash their original representation before value normalization" do
    raw = activity(type: "Trades", quantity: BigDecimal("0.0000001"), netAmount: BigDecimal("-2.5"))
    record = @adapter.normalize_legacy_activity(raw, account: @account).sole
    assert_equal "questrade_trade_#{legacy_digest(raw)}", record[:external_id]
    assert_equal BigDecimal("0.000001"), record[:amount]
  end

  test "native identity encoding rejects decimals outside the finite nonzero legacy number range" do
    %w[1e400 1e-400].each do |quantity|
      raw = JSON.parse(numeric_activity_json(quantity: quantity, net: "-2.0"), symbolize_names: true, decimal_class: BigDecimal)
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @account) }
    end
  end

  test "colliding legacy number identities cannot collapse distinct exact activities in one page" do
    rows = %w[-1.00000000000000001 -1.00000000000000002].map do |net|
      JSON.parse(numeric_activity_json(quantity: "2.0", net: net), symbolize_names: true, decimal_class: BigDecimal)
        .merge(type: "Deposits", symbol: "")
    end
    @client.expects(:get_ingestion_activities).returns(activities: rows)
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.fetch_activities(account: @account, window: { start: "2026-09-01", end: "2026-09-14" })
    end
  end

  test "missing price retains legacy net fallback but does not pretend to satisfy the trade writer" do
    record = @adapter.normalize_activity(activity(type: "Trades", price: nil, netAmount: "-12.34"), account: @account).sole
    assert_equal BigDecimal("12.34"), record[:amount]
    assert_nil record[:price]
    refute @adapter.class.native_ready?
  end

  test "missing trade prices retain evidence without posting either the trade or its commission" do
    missing = activity(type: "Trades", price: nil, commission: "-0.50", netAmount: "-12.34")
    cash = activity(type: "Deposits", description: "Independent deposit")
    @client.expects(:get_ingestion_activities).returns(activities: [ missing, cash ])

    page = @adapter.fetch_activities(account: @account, window: { start: "2026-09-01", end: "2026-09-14" })

    refute page.complete?
    assert_nil page.next_cursor
    assert_nil page.checkpoint_cursor
    assert page.progress_cursor.present?
    assert_equal [ "questrade_cash_#{legacy_digest(cash)}" ], page.records.map { |record| record[:external_id] }
    assert_equal [ missing, cash ], page.evidence["response"][:activities]
    assert_includes page.warnings, { "code" => "missing_trade_price", "count" => 1 }
    assert_includes page.warnings, { "code" => "unresolved_trade_history" }
    refute page.coverage.fetch("absence_authoritative")
  end

  test "unresolved prices survive later valid windows and retry the original scope on a later day" do
    missing = activity(type: "Trades", price: nil, commission: "-0.50")
    @client.expects(:get_ingestion_activities).returns(activities: [ missing ])
    first = @adapter.fetch_activities(account: @account, window: { start: "2026-08-01", end: "2026-09-14" })
    @client.expects(:get_ingestion_activities).returns(activities: [ activity(type: "Deposits") ])
    last = @adapter.fetch_activities(account: @account, cursor: first.next_cursor)

    refute first.complete?
    assert first.next_cursor.present?
    refute last.complete?
    assert_nil last.next_cursor
    assert_equal first.progress_cursor, last.progress_cursor
    assert_equal 1, last.records.size
    assert_includes last.warnings, { "code" => "unresolved_trade_history" }

    retry_adapter = Provider::AccountData::Questrade.new(client: @client, timezone: "America/Toronto", observed_at: Time.utc(2026, 12, 1))
    @client.expects(:get_ingestion_activities).with(account_id: "123", start_time: "2026-08-01T04:00:00.000000Z", end_time: "2026-08-31T03:59:59.999999Z")
      .returns(activities: [ missing.merge(price: "10") ])
    retried = retry_adapter.fetch_activities(account: @account, cursor: last.progress_cursor)
    assert_equal %w[buy fee], retried.records.map { |record| record[:activity_type] }
    assert_nil retried.progress_cursor
    @client.expects(:get_ingestion_activities).with(account_id: "123", start_time: "2026-08-31T04:00:00.000000Z", end_time: "2026-09-15T03:59:59.999999Z")
      .returns(activities: [])
    completed = retry_adapter.fetch_activities(account: @account, cursor: retried.next_cursor)
    assert completed.complete?
    assert_nil completed.progress_cursor
    assert_equal first.coverage, completed.coverage
  end

  test "unresolved cursor state must be a boolean" do
    @client.expects(:get_ingestion_activities).returns(activities: [])
    page = @adapter.fetch_activities(account: @account, window: { start: "2026-08-01", end: "2026-09-14" })
    scope = JSON.parse(Base64.strict_decode64(page.next_cursor))
    [ nil, "false", 0, {} ].each do |invalid|
      cursor = Base64.strict_encode64(JSON.generate(scope.merge("unresolved" => invalid)))
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @account, cursor: cursor) }
    end
    @client.expects(:get_ingestion_activities).returns(activities: [])
    # Cursors captured before this field existed retain their original meaning.
    assert @adapter.fetch_activities(account: @account, cursor: Base64.strict_encode64(JSON.generate(scope.except("unresolved")))).complete?
  end

  test "activity time zones are explicit and malformed dates are quarantined" do
    raw = activity(type: "Deposits", settlementDate: "2026-09-12T02:00:00Z")
    assert_equal Date.new(2026, 9, 11), @adapter.normalize_activity(raw, account: @account).sole[:date]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw.merge(settlementDate: "bad"), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw.merge(accountId: "999"), account: @account) }
  end

  test "activity windows are bounded non-overlapping resumable pages and retain every response" do
    @client.expects(:get_ingestion_activities).with(account_id: "123", start_time: "2026-08-01T04:00:00.000000Z", end_time: "2026-08-31T03:59:59.999999Z")
      .returns(activities: [ activity(type: "FX conversion") ])
    @client.expects(:get_ingestion_activities).with(account_id: "123", start_time: "2026-08-31T04:00:00.000000Z", end_time: "2026-09-15T03:59:59.999999Z")
      .returns(activities: [])
    page = @adapter.fetch_activities(account: @account, window: { start: "2026-08-01", end: "2026-09-14" })
    refute page.complete?
    assert_equal "unmapped_or_nonfinancial_activities", page.warnings.first["code"]
    assert_equal 1, page.evidence["response"][:activities].size
    final = @adapter.fetch_activities(account: @account, cursor: page.next_cursor)
    assert final.complete?
    assert_nil final.next_cursor
    assert_equal page.coverage, final.coverage
  end

  test "a failed later history page cannot be mistaken for complete coverage" do
    @client.expects(:get_ingestion_activities).returns(activities: [])
    first = @adapter.fetch_activities(account: @account, window: { start: "2026-08-01", end: "2026-09-14" })
    @client.expects(:get_ingestion_activities).raises(Provider::Questrade::Error.new("unavailable", :network_error))
    assert_raises(Provider::Questrade::Error) { @adapter.fetch_activities(account: @account, cursor: first.next_cursor) }
    refute first.complete?
  end

  test "cursor cannot be replayed against another account" do
    @client.expects(:get_ingestion_activities).returns(activities: [])
    page = @adapter.fetch_activities(account: @account, window: { start: "2026-08-01", end: "2026-09-14" })
    other = @adapter.normalize_account(number: "999", type: "TFSA")
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: other, cursor: page.next_cursor) }
  end

  test "a first shared scan covers three years and subsequent scans overlap thirty days" do
    @client.expects(:get_ingestion_activities).with do |args|
      assert_equal "2023-09-15T04:00:00.000000Z", args[:start_time]
      true
    end.returns(activities: [])
    first = @adapter.fetch_activities(account: @account, window: { initial: true, start: "2026-06-14", end: "2026-09-14" })
    refute first.complete?
    @client.expects(:get_ingestion_activities).with do |args|
      assert_equal "2026-08-14T04:00:00.000000Z", args[:start_time]
      true
    end.returns(activities: [])
    @adapter.fetch_activities(account: @account, window: { initial: false, checkpoint_covered_through: "2026-09-13T12:00:00Z", end: "2026-09-14" })
  end

  test "distinct currency rows with a colliding legacy ID fail instead of silently overwriting" do
    @client.expects(:get_ingestion_activities).returns(activities: [ activity(type: "Deposits", currency: "CAD"), activity(type: "Deposits", currency: "USD") ])
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @account, window: { start: "2026-09-01", end: "2026-09-14" }) }
  end

  private
    def build_adapter
      Provider::AccountData::Questrade.new(client: @client, timezone: "America/Toronto", observed_at: Time.utc(2026, 9, 14, 12))
    end

    def balances(per: [ { currency: "CAD", cash: "50", totalEquity: "500" } ], combined: [ { currency: "CAD", totalEquity: "500" } ])
      { perCurrencyBalances: per, combinedBalances: combined }
    end

    def holding(**overrides)
      { symbol: "VFV.TO", symbolId: 456, openQuantity: "2", currentPrice: "12.34567890123456789",
        averageEntryPrice: "8.75", currency: "CAD" }.merge(overrides)
    end

    def activity(**overrides)
      { type: "Deposits", action: "Buy", symbol: "VFV.TO", symbolId: 456, quantity: "2", price: "10", netAmount: "-20", commission: "0",
        description: "Vanguard index fund", currency: "CAD", transactionDate: "2026-09-11T00:00:00-04:00",
        tradeDate: "2026-09-10T00:00:00-04:00", settlementDate: "2026-09-12T00:00:00-04:00" }.merge(overrides)
    end

    def legacy_digest(raw)
      Digest::SHA256.hexdigest(%i[transactionDate action symbolId quantity netAmount description].map { |key| raw[key] }.join("|")).first(24)
    end

    def numeric_activity_json(quantity:, net:)
      <<~JSON
        {"type":"Trades","action":"Buy","symbol":"AAPL","symbolId":456,
         "quantity":#{quantity},"price":1.234567890123456789,"netAmount":#{net},"commission":-0.01234567890123456789,
         "description":"Original activity","currency":"CAD","transactionDate":"2026-09-11T12:00:00-04:00"}
      JSON
    end
end
