require "test_helper"

class Provider::AccountData::IndexaCapitalTest < ActiveSupport::TestCase
  setup do
    @client = mock("Indexa exact transport")
    @adapter = build_adapter
    @account = @adapter.normalize_account(account_number: "ACCOUNT1", type: "mutual", status: "active")
  end

  test "live capabilities expose holdings without inventing transaction or activity history" do
    assert_equal [ "holdings" ], @adapter.class.definition.capabilities
    assert_raises(Provider::AccountData::UnsupportedCapability) { @adapter.fetch_transactions(account: @account) }
    assert_raises(Provider::AccountData::UnsupportedCapability) { @adapter.fetch_activities(account: @account) }
    refute @adapter.class.native_ready?
  end

  test "account inventory preserves names identity and EUR without inferring balances" do
    raw = { accounts: [ { account_number: "ACCOUNT1", type: "pension", status: "active" } ], private_user_data: "private-name" }
    @client.expects(:get_ingestion_accounts).returns(raw)
    page = @adapter.list_accounts
    assert page.complete?
    assert_equal "Indexa Capital Pension Plan (ACCOUNT1)", page.records.first[:name]
    assert_equal "ACCOUNT1", page.records.first[:external_id]
    assert_equal "EUR", page.records.first[:currency]
    assert_equal false, page.records.first[:metadata][:balance_provided]
    assert_equal raw, page.evidence["response"]
    refute_includes page.records.first[:metadata].to_s, "private-name"
  end

  test "performance balance chooses latest date instead of largest value or row order" do
    response = { portfolios: [ { date: "2026-09-13", total_amount: "123.456789012345678" },
      { date: "2026-09-01", total_amount: "999999" } ] }
    @client.expects(:get_ingestion_performance).with(account_number: "ACCOUNT1").returns(response)
    page = @adapter.fetch_balance(account: @account)
    assert_equal BigDecimal("123.456789012345678"), page.records.first[:balance]
    assert_equal BigDecimal("0"), page.records.first[:cash_balance]
    assert_equal true, page.records.first[:metadata].with_indifferent_access.dig(:balance_policy, :current_anchor)
    assert_equal response, page.evidence["response"]
  end

  test "explicit empty performance retains legacy zero but missing history is an error" do
    @client.expects(:get_ingestion_performance).returns(portfolios: [])
    assert_equal BigDecimal("0"), @adapter.fetch_balance(account: @account).records.first[:balance]
    @client.expects(:get_ingestion_performance).returns({})
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @account) }
  end

  test "performance network failure preserves captured account balance and margin cash" do
    adapter = build_adapter(external_accounts: [ { external_id: "ACCOUNT1", current_balance: BigDecimal("1234"), cash_balance: BigDecimal("-25") } ])
    @client.expects(:get_ingestion_performance).raises(Provider::IndexaCapital::Error.new("failed", :network_error))
    page = adapter.fetch_balance(account: @account)
    assert_equal BigDecimal("1234"), page.records.first[:balance]
    assert_equal BigDecimal("-25"), page.records.first[:cash_balance]
    assert_equal "performance_balance_unavailable", page.warnings.first["code"]
    assert_equal BigDecimal("1234"), page.evidence["fallback_balance"]
  end

  test "missing cached balance falls back to one holding per instrument plus cash" do
    @client.expects(:get_ingestion_performance).raises(Provider::IndexaCapital::Error.new("failed", :network_error))
    @client.expects(:get_ingestion_fiscal_results).returns(total_fiscal_results: [ holding(amount: "5"), holding(amount: "20") ])
    page = @adapter.fetch_balance(account: @account)
    assert_equal BigDecimal("20"), page.records.first[:balance]
  end

  test "authentication failures never become a cached successful balance" do
    @client.expects(:get_ingestion_performance).raises(Provider::IndexaCapital::AuthenticationError.new("expired", :unauthorized))
    assert_raises(Provider::IndexaCapital::AuthenticationError) { @adapter.fetch_balance(account: @account) }
  end

  test "aggregated fiscal positions take precedence over historical tax lots" do
    response = { total_fiscal_results: [ holding(amount: "20", titles: "2") ], fiscal_results: [ holding(amount: "9999", titles: "999") ] }
    @client.expects(:get_ingestion_fiscal_results).returns(response)
    @client.expects(:get_ingestion_portfolio).never
    page = @adapter.fetch_holdings(account: @account)
    assert_equal BigDecimal("20"), page.records.first[:amount]
    assert_equal BigDecimal("2"), page.records.first[:quantity]
    assert_equal response, page.evidence["fiscal_results"]
    assert_equal "delta", page.mode
  end

  test "pension portfolio fallback derives per-unit cost basis" do
    @client.expects(:get_ingestion_fiscal_results).returns(total_fiscal_results: [], fiscal_results: [])
    portfolio = { instrument_accounts: [ { positions: [ holding(cost_price: nil, cost_amount: "12", titles: "3") ] } ] }
    @client.expects(:get_ingestion_portfolio).returns(portfolio)
    page = @adapter.fetch_holdings(account: @account)
    assert_equal BigDecimal("4"), page.records.first[:metadata][:cost_basis]
    assert_equal portfolio, page.evidence["portfolio"]
  end

  test "holding observation includes date while financial identity remains security date currency" do
    first = @adapter.normalize_holding(holding, account: @account)
    later = build_adapter(observed_at: Time.utc(2026, 9, 15, 12)).normalize_holding(holding, account: @account)
    assert_equal "indexa_capital_IE00BFPM9V94_2026-09-14", first[:external_id]
    refute_equal first[:external_id], later[:external_id]
    assert_equal "security_date_currency", first[:metadata][:holding_identity]
    assert_equal false, first[:metadata][:delete_future_holdings]
    assert_equal "ticker_only", first[:security][:lookup]
  end

  test "holding security descriptor preserves ISIN ticker and legacy MIC column" do
    record = @adapter.normalize_holding(holding(exchange: { mic_code: "XOLD" }, currency: "GBP"), account: @account)
    assert_equal "IE00BFPM9V94", record[:security][:ticker]
    assert_equal "Index fund", record[:security][:name]
    assert_equal "XOLD", record[:security][:exchange_mic]
    assert_nil record[:security][:exchange_operating_mic]
    assert_equal "GB", record[:security][:country_code]
    assert_equal true, record[:security][:repair_malformed_name]
  end

  test "foreign holdings and malformed exact values cannot reach the ledger" do
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(holding(account: "OTHER"), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(holding(titles: nil), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(holding(price: 1.5), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_holding(holding(instrument: {}), account: @account) }
  end

  test "legacy float caches use explicit conversion for holdings and accounts" do
    raw = holding(titles: 2.5, price: 10.25, amount: 25.625, cost_price: 4.2)
    record = @adapter.normalize_legacy_holding(raw, account: @account)
    assert_equal BigDecimal("25.625"), record[:amount]
    assert_instance_of Float, raw[:titles]
    cached = @adapter.normalize_legacy_account(account_number: "ACCOUNT1", type: "mutual", name: "Cached name", current_balance: 123.45)
    assert_equal "Cached name", cached[:name]
    assert_equal BigDecimal("123.45"), cached[:balance]
  end

  test "cash activity signs labels and exact legacy IDs survive" do
    { "CONTRIBUTION" => [ "contribution", "Contribution", -5 ], "DIVIDEND" => [ "dividend", "Dividend", -5 ],
      "DIV" => [ "dividend", "Dividend", -5 ], "TRANSFER_IN" => [ "transfer", "Transfer", -5 ],
      "TRANSFER_OUT" => [ "transfer", "Transfer", 5 ], "WITHDRAWAL" => [ "withdrawal", "Withdrawal", 5 ],
      "INTEREST" => [ "interest", "Interest", -5 ], "FEE" => [ "fee", "Fee", 5 ], "TAX" => [ "fee", "Fee", 5 ] }.each do |type, expected|
      record = @adapter.normalize_activity(activity(type: type, amount: "-5"), account: @account)
      assert_equal expected[0], record[:activity_type]
      assert_equal expected[1], record[:metadata][:investment_activity_label]
      assert_equal BigDecimal(expected[2].to_s), record[:amount]
      assert_equal "original-id", record[:external_id]
    end
  end

  test "trade and reinvestment direction preserve quantity price and labels" do
    { "BUY" => [ "buy", 2, "Buy" ], "SELL" => [ "sell", -2, "Sell" ], "REINVEST" => [ "buy", 2, "Reinvestment" ] }.each do |type, expected|
      record = @adapter.normalize_activity(activity(type: type, units: "-2", price: "3", symbol: "IE00BFPM9V94"), account: @account)
      assert_equal expected[0], record[:activity_type]
      assert_equal BigDecimal(expected[1].to_s), record[:quantity]
      assert_equal BigDecimal((expected[1] * 3).to_s), record[:amount]
      assert_equal expected[2], record[:metadata][:investment_activity_label]
    end
  end

  test "other historical cash events retain their amount without inventing a trade" do
    %w[TRANSFER SPLIT MERGER OTHER PROVIDER_SPECIFIC].each do |type|
      record = @adapter.normalize_activity(activity(type: type, amount: "0"), account: @account)
      assert_equal(type == "TRANSFER" ? "transfer" : "other", record[:activity_type])
      assert_equal BigDecimal("0"), record[:amount]
      assert_nil record[:security]
    end
  end

  test "historical activity float caches use explicit decimal conversion" do
    raw = activity(type: "CONTRIBUTION", amount: 5.25)
    record = @adapter.normalize_legacy_activity(raw, account: @account)
    assert_equal BigDecimal("-5.25"), record[:amount]
    assert_instance_of Float, raw[:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @account) }
  end

  test "activity settlement timestamps use family timezone and absent dates use captured observation date" do
    record = @adapter.normalize_activity(activity(settlement_date: "2026-09-14T01:00:00Z", trade_date: "2026-09-12"), account: @account)
    assert_equal Date.new(2026, 9, 13), record[:date]
    missing = @adapter.normalize_activity(activity(date: nil), account: @account)
    assert_equal Date.new(2026, 9, 14), missing[:date]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(activity(date: "malformed"), account: @account) }
  end

  test "factory honors stored token before explicit deployment fallback" do
    Provider::IndexaCapital.expects(:new).with(api_token: "stored-token").returns(@client)
    adapter = @adapter.class.build(credentials: { api_token: "stored-token" }, settings: {},
      context: { timezone: "UTC", observed_at: Time.utc(2026, 9, 14), external_accounts: [], fallback_credentials: { api_token: "deployment-token" } })
    refute_includes adapter.inspect, "stored-token"
  end

  private
    def build_adapter(**options)
      Provider::AccountData::IndexaCapital.new(**{ client: @client, timezone: "America/Los_Angeles", observed_at: Time.utc(2026, 9, 14, 12) }.merge(options))
    end

    def holding(**attributes)
      { instrument: { identifier: "IE00BFPM9V94", name: "Index fund" }, titles: "2", price: "10", amount: "20", cost_price: "4" }.merge(attributes)
    end

    def activity(**attributes)
      { id: "original-id", type: "CONTRIBUTION", amount: "5", date: "2026-09-13" }.merge(attributes)
    end
end
