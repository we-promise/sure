require "test_helper"

class SaxoAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).saxo_items.create!
    @provider_account = @item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR",
      current_balance: 1100, cash_balance: 100, account_type: "PEA")
    @account = @provider_account.link!
    @processor = SaxoAccount::Processor.new(@provider_account)
  end

  test "holdings are grouped by listing and value in account currency" do
    holdings = @processor.normalize_positions([ position, position ])
    assert_equal 1, holdings.size
    assert_equal BigDecimal("4"), holdings.values.first[:quantity]
    assert_equal BigDecimal("200"), holdings.values.first[:amount]
  end

  test "positions require a valid UIC" do
    [ nil, "", " ", "abc", 0, -1 ].each do |uic|
      row = position
      row["PositionBase"]["Uic"] = uic
      assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
    end
  end

  test "an ETC position imports as a holding with a stable listing identity" do
    row = position
    row["PositionBase"]["AssetType"] = "Etc"
    holdings = @processor.normalize_positions([ row ])

    2.times { @processor.process({ trades: {}, bookings: {} }, holdings) }

    holding = @account.holdings.find_by!(date: Date.current)
    assert_equal "SAXO-ETC:101", holding.security.ticker
    assert_equal BigDecimal("2"), holding.qty
    assert_equal BigDecimal("100"), holding.amount
    assert_equal 1, @account.holdings.count
  end

  test "unreliable or missing calculation reliability rejects numeric position values" do
    [ "PricePending", nil ].each do |reliability|
      row = position
      row["PositionView"]["CalculationReliability"] = reliability
      row["PositionView"]["CurrentPrice"] = "0"
      row["PositionView"]["MarketValueInBaseCurrency"] = "0"

      error = assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
      assert_equal "Saxo position valuation is unreliable", error.message
      assert_equal({ stage: "positions", reason: "unreliable_valuation",
        calculation_reliability: reliability || "missing", price_present: true, value_present: true,
        market_data_may_be_unavailable: false,
        account_provider_id: @provider_account.account_provider.id }, error.diagnostic)
    end
  end

  test "conditional Saxo valuations are accepted when position values are positive" do
    row = position
    row["PositionView"]["CalculationReliability"] = "OkWithConditions"

    holdings = @processor.normalize_positions([ row ])
    assert_equal BigDecimal("2"), holdings.values.first[:quantity]
    assert_equal BigDecimal("100"), holdings.values.first[:amount]
  end

  test "conditional Saxo valuations with an open position and zero price are rejected" do
    row = position
    row["PositionView"]["CalculationReliability"] = "OkWithConditions"
    row["PositionView"]["CurrentPrice"] = 0
    assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
  end

  test "unavailable market data gives an actionable error without importing zero values" do
    [ "NoMarketAccess", "ApproximatedPrice" ].each do |reliability|
      row = position
      row["PositionView"].merge!("CalculationReliability" => reliability, "CurrentPrice" => 0, "MarketValueInBaseCurrency" => 0)

      error = assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
      assert_equal "Saxo market data may be unavailable", error.message
      assert_equal true, error.diagnostic[:market_data_may_be_unavailable]
    end
  end

  test "a nonzero approximated price is not assumed to mean missing market access" do
    row = position
    row["PositionView"]["CalculationReliability"] = "ApproximatedPrice"

    error = assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
    assert_equal "Saxo position valuation is unreliable", error.message
    assert_equal false, error.diagnostic[:market_data_may_be_unavailable]
  end

  test "position diagnostics do not record unrecognized reliability values or instrument details" do
    row = position
    row["PositionView"]["CalculationReliability"] = "private-information"
    row["PositionView"].delete("CurrentPrice")
    row["DisplayAndFormat"]["Symbol"] = "private-symbol"

    error = assert_raises(Provider::Saxo::Error) { @processor.normalize_positions([ row ]) }
    assert_equal "unknown", error.diagnostic[:calculation_reliability]
    assert_equal false, error.diagnostic[:price_present]
    assert_no_match(/private-information|private-symbol/, error.diagnostic.inspect)
  end

  test "a complete empty snapshot closes positions without deleting history" do
    security = securities(:aapl)
    @account.holdings.create!(security: security, account_provider: @provider_account.account_provider,
      date: Date.yesterday, qty: 2, amount: 100, price: 50, currency: "EUR")
    @processor.process({ trades: {}, bookings: {} }, {})
    assert_equal 2, @account.holdings.count
    assert_equal 2, @account.holdings.find_by!(date: Date.yesterday).qty
    assert_equal 0, @account.holdings.find_by!(date: Date.current).qty
    assert_equal BigDecimal("1100"), @account.reload.balance
    assert_equal BigDecimal("100"), @account.cash_balance
  end

  test "repeated processing never duplicates trades or fees" do
    instrument = { "Uic" => 101, "AssetType" => "Stock", "Currency" => "EUR", "Symbol" => "EXAMPLE" }
    normalized = { trades: { "trade" => { instrument: instrument, quantity: BigDecimal("2"), price: BigDecimal("50"),
      amount: BigDecimal("100"), currency: "EUR", date: Date.current, activity_label: "Buy", conversion_rate: BigDecimal("1") } },
      bookings: { "fee" => { amount: BigDecimal("2"), currency: "EUR", date: Date.current, name: "Commission", activity_label: "Fee" } } }
    2.times { @processor.process(normalized, {}) }
    assert_equal 1, @account.entries.where(source: "saxo", entryable_type: "Trade").count
    assert_equal 1, @account.entries.where(source: "saxo", entryable_type: "Transaction").count
  end

  test "a transferred security is imported without a cash movement" do
    row = { "AccountId" => "123", "Currency" => "EUR", "Date" => "2026-10-20", "TransactionType" => "Trade",
      "Event" => "Transfer In", "BookedAmount" => "0", "Bookings" => [],
      "Trades" => [ { "TradeId" => "transfer", "TradedQuantity" => "2", "Price" => "0",
        "Instrument" => { "Uic" => 101, "AssetType" => "Stock", "Currency" => "EUR", "Symbol" => "EXAMPLE" } } ] }
    normalized = Provider::Saxo::Normalizer.new(account_id: "123", currency: "EUR").call([ row ])

    2.times { @processor.process(normalized, {}) }

    entry = @account.entries.find_by!(source: "saxo", external_id: "123:trade:transfer")
    assert_equal 0, entry.amount
    assert_equal 2, entry.entryable.qty
    assert_equal "Transfer", entry.entryable.investment_activity_label
    assert_equal 1, @account.entries.where(source: "saxo").count
  end

  test "an active remapped position stays open and retains the chosen security when sold" do
    normalized = { trades: {}, bookings: {} }
    holdings = @processor.normalize_positions([ position ])
    @processor.process(normalized, holdings)
    @account.holdings.find_by!(date: Date.current).remap_security!(securities(:aapl))
    @processor.process(normalized, holdings)
    assert_equal BigDecimal("2"), @account.holdings.find_by!(date: Date.current).qty
    travel 1.day do
      @processor.process(normalized, holdings)
      current = @account.holdings.find_by!(date: Date.current)
      assert_equal securities(:aapl).id, current.security_id
      assert_equal BigDecimal("2"), current.qty
      @processor.process(normalized, {})
      assert_equal BigDecimal("0"), current.reload.qty
      assert current.security_locked?
    end
  end

  test "materialized total already includes the positions and leaves the remaining cash" do
    positions = [ position ]
    positions[0]["PositionBase"]["Amount"] = "20"
    positions[0]["PositionView"]["MarketValueInBaseCurrency"] = "1000"
    @processor.process({ trades: {}, bookings: {} }, @processor.normalize_positions(positions))
    Balance::Materializer.new(@account, strategy: :reverse).materialize_balances
    balance = @account.balances.find_by!(date: Date.current, currency: "EUR")
    assert_equal BigDecimal("1100"), balance.end_balance
    assert_equal BigDecimal("100"), balance.end_cash_balance
    assert_equal BigDecimal("1000"), balance.end_non_cash_balance
  end

  test "provider corrections update untouched bookings and preserve manual changes" do
    booking = { amount: BigDecimal("2"), currency: "EUR", date: Date.current, name: "Commission", activity_label: "Fee" }
    normalized = { trades: {}, bookings: { "fee" => booking } }
    @processor.process(normalized, {})
    entry = @account.entries.find_by!(source: "saxo", external_id: "123:booking:fee")
    booking[:amount] = BigDecimal("3")
    @processor.process(normalized, {})
    assert_equal BigDecimal("3"), entry.reload.amount
    entry.update!(name: "My correction", user_modified: true)
    booking[:amount] = BigDecimal("4")
    @processor.process(normalized, {})
    assert_equal BigDecimal("3"), entry.reload.amount
    assert_equal "My correction", entry.name
    assert_equal 1, @account.entries.where(source: "saxo").count
  end

  private
    def position
      { "PositionBase" => { "AccountId" => "123", "AssetType" => "Stock", "Uic" => 101, "Amount" => "2" },
        "PositionView" => { "CalculationReliability" => "Ok", "CurrentPrice" => "50", "MarketValueInBaseCurrency" => "100" },
        "DisplayAndFormat" => { "Symbol" => "EXAMPLE", "Currency" => "EUR" } }
    end
end
