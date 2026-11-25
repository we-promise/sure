require "test_helper"

# A zero-amount Transfer trade moves a position in or out without cash. Its
# value is a non-cash flow, not a market move: the value the holdings give the
# position that day, so the day's market movement is what is left.
class Balance::TransferTradeFlowsTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  def transfer_day
    1.day.ago.to_date
  end

  def add_trade(account, qty:, price:, label: Trade::TRANSFER_LABEL, currency: "USD", exchange_rate: nil, extra: nil)
    security = Security.find_by!(ticker: "AAPL")
    trade = Trade.new(qty: qty, security: security, price: price, currency: currency, investment_activity_label: label)
    trade.exchange_rate = exchange_rate if exchange_rate
    trade.extra = (trade.extra || {}).merge(extra) if extra
    account.entries.create!(name: "Transfer", date: transfer_day, amount: 0, currency: currency, entryable: trade)
  end

  # 5000 of cash from 3 days ago; 10 AAPL worth 1000 at the close of the
  # transfer day, and still today.
  def forward_account
    create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
  end

  def flows_on(calculated, date)
    calculated.find { |balance| balance.date == date }
  end

  test "forward: a transfer in is a non-cash inflow at the holdings' price for the day, not the trade's" do
    account = forward_account
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.cash_outflows
    assert_equal 0, day.net_market_flows
    assert_equal 5000, day.cash_balance
    assert_equal 6000, day.balance
  end

  test "forward: a transfer with no price of its own is valued at the holdings' price too" do
    account = forward_account
    add_trade(account, qty: 10, price: 0)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: transfers in at different prices, one of them none, are valued alike" do
    account = forward_account
    add_trade(account, qty: 6, price: 90)
    add_trade(account, qty: 4, price: 0)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a zero-amount trade with another label is unchanged" do
    account = forward_account
    add_trade(account, qty: 10, price: 95, label: "Buy")

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 1000, day.net_market_flows
  end

  test "forward: a transfer in another currency is valued at the holdings' price, not at its own rate" do
    account = forward_account
    add_trade(account, qty: 10, price: 80, currency: "EUR", exchange_rate: 1.2)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: holdings in another currency than the account's are converted as their value is" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000, currency: "EUR" },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000, currency: "EUR" }
      ]
    )
    [ transfer_day, Date.current ].each { |date| ExchangeRate.create!(date: date, from_currency: "EUR", to_currency: "USD", rate: 1.2) }
    add_trade(account, qty: 10, price: 80, currency: "EUR", exchange_rate: 1.1)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1200, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer is valued at its own price where no rate converts the holdings' currency" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000, currency: "GBP" },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000, currency: "GBP" }
      ]
    )
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 950, day.non_cash_inflows
  end

  test "reverse: a transfer in is a non-cash inflow at the holdings' price for the day" do
    # 5000 of cash and 10 AAPL worth 1000 today, which arrived by transfer on
    # the transfer day at 95.
    account = create_account_with_ledger(
      account: { type: Investment, balance: 6000, cash_balance: 5000, currency: "USD" },
      entries: [ { type: "current_anchor", date: Date.current, balance: 6000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ReverseCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
    assert_equal 5000, day.cash_balance
  end

  test "reverse: a transfer out of a whole position is an outflow at the price the day before" do
    # 10 AAPL worth 1000 two days ago leave at 105 on the transfer day.
    account = create_account_with_ledger(
      account: { type: Investment, balance: 5000, cash_balance: 5000, currency: "USD" },
      entries: [ { type: "current_anchor", date: Date.current, balance: 5000 } ],
      holdings: [ { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 } ]
    )
    add_trade(account, qty: -10, price: 105)

    day = flows_on(Balance::ReverseCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a whole position out is valued at the price of the day it leaves when the holdings record one" do
    # The close of the day has a priced row with no shares, as a materialized sync writes it.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: transfer_day, ticker: "AAPL", qty: 0, price: 120, amount: 0 }
      ]
    )
    add_trade(account, qty: -10, price: 105)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1200, day.non_cash_outflows
    assert_equal 200, day.net_market_flows
  end

  test "forward: a whole position out on the day of a split is valued at the post-split price of the day before" do
    # 10 shares at 100 become 20 at 50 on the transfer day, and all 20 leave.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [ { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 } ]
    )
    Security.find_by!(ticker: "AAPL").splits.create!(ex_date: transfer_day, numerator: 2, denominator: 1, source: "manual")
    add_trade(account, qty: -20, price: 50)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a flow is rounded to the holdings' scale so no market movement is left" do
    # 0.333333333333333333 shares at 100.1234 are 33.37446666... and the
    # holding stores them as 33.3745.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: BigDecimal("0.333333333333333333"), price: BigDecimal("100.1234"), amount: BigDecimal("33.3745") },
        { date: Date.current, ticker: "AAPL", qty: BigDecimal("0.333333333333333333"), price: BigDecimal("100.1234"), amount: BigDecimal("33.3745") }
      ]
    )
    add_trade(account, qty: BigDecimal("0.333333333333333333"), price: 0)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal BigDecimal("33.3745"), day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer out of part of a position is valued at the day's price" do
    # 20 shares at 98 become 10 at 100 on the transfer day, 10 of them leaving.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: 20, price: 98, amount: 1960 },
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
    add_trade(account, qty: -10, price: 95)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_outflows
    assert_equal 40, day.net_market_flows
  end

  test "forward: the two legs of a move between your own accounts are valued alike" do
    # One leaves at a price of its own, the other arrives with none.
    from = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [ { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 } ]
    )
    add_trade(from, qty: -10, price: 105)
    to = forward_account
    add_trade(to, qty: 10, price: 0)

    out_day = flows_on(Balance::ForwardCalculator.new(from).calculate, transfer_day)
    in_day = flows_on(Balance::ForwardCalculator.new(to).calculate, transfer_day)

    assert_equal 1000, out_day.non_cash_outflows
    assert_equal 1000, in_day.non_cash_inflows
    assert_equal 0, out_day.net_market_flows + in_day.net_market_flows
  end

  test "reverse: a transfer with no price of its own is valued at the holdings' price too" do
    account = create_account_with_ledger(
      account: { type: Investment, balance: 6000, cash_balance: 5000, currency: "USD" },
      entries: [ { type: "current_anchor", date: Date.current, balance: 6000 } ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
    add_trade(account, qty: 10, price: 0)

    day = flows_on(Balance::ReverseCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end
  test "forward: a transfer of a position the holdings never valued is no flow" do
    # No price, so no holding: the move is not in the holdings value, and a
    # flow for it would only turn into market gain.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ]
    )
    Security.find_or_create_by!(ticker: "AAPL") { |security| security.name = "AAPL" }
    add_trade(account, qty: -10, price: 105)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "reverse: a transfer on the opening anchor's date leaves the day's balance identity intact" do
    account = create_account_with_ledger(
      account: { type: Investment, balance: 6000, cash_balance: 5000, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: transfer_day, balance: 6000 },
        { type: "current_anchor", date: Date.current, balance: 6000 }
      ],
      holdings: [
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ReverseCalculator.new(account).calculate, transfer_day)
    end_balance = day.start_cash_balance + day.start_non_cash_balance +
      (day.cash_inflows - day.cash_outflows) + (day.non_cash_inflows - day.non_cash_outflows) +
      day.net_market_flows + day.cash_adjustments + day.non_cash_adjustments

    assert_equal 6000, day.balance
    assert_equal day.balance, end_balance
  end
  # Same-day trades: the position is back to nothing at a close, so the
  # holdings row there has a price but no amount.
  def same_day_account(trade_qty)
    create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 },
        { type: "trade", date: transfer_day, ticker: "AAPL", qty: trade_qty, price: 100 }
      ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: 0, price: 100, amount: 0 },
        { date: transfer_day, ticker: "AAPL", qty: 0, price: 100, amount: 0 },
        { date: Date.current, ticker: "AAPL", qty: 0, price: 100, amount: 0 }
      ]
    )
  end

  test "forward: shares bought and transferred out on one day are a flow both ways" do
    account = same_day_account(10)
    add_trade(account, qty: -10, price: 100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 1000, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: shares transferred in and sold on one day are a flow both ways" do
    account = same_day_account(-10)
    add_trade(account, qty: 10, price: 100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 1000, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end
  # Through the holdings materializer, for a security with no stored prices:
  # only the trades price it, and only on their own day.
  def materialized_day(*trades)
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ]
    )
    Security.find_or_create_by!(ticker: "AAPL") { |security| security.name = "AAPL" }
    trades.each { |qty| add_trade(account, qty: qty, price: 100) }

    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    account.balances.find_by!(date: transfer_day)
  end

  test "materialized: a transfer is valued at the stored price of the day, not the trade's" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      security_prices: [
        { ticker: "AAPL", date: 2.days.ago.to_date, price: 98 },
        { ticker: "AAPL", date: transfer_day, price: 100 },
        { ticker: "AAPL", date: Date.current, price: 101 }
      ]
    )
    add_trade(account, qty: 10, price: 95)

    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    day = account.balances.find_by!(date: transfer_day)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "materialized: a transfer with no price is valued at the nearest quote the holdings use" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 40.days.ago.to_date, balance: 5000 } ],
      security_prices: [ { ticker: "AAPL", date: 30.days.ago.to_date, price: 80 } ]
    )
    add_trade(account, qty: 10, price: 0)

    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    day = account.balances.find_by!(date: transfer_day)

    assert_equal 800, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "materialized: a transfer of a security with no price anywhere is no flow" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ]
    )
    Security.find_or_create_by!(ticker: "AAPL") { |security| security.name = "AAPL" }
    add_trade(account, qty: 10, price: 0)

    Balance::Materializer.new(account, strategy: :forward).materialize_balances
    day = account.balances.find_by!(date: transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "materialized: a position transferred in and out on the day it first arrives is no flow" do
    # The holdings hold none before or after, so they never show it.
    day = materialized_day(10, -10)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "materialized: part of a position transferred out on the day it first arrives is a flow both ways" do
    day = materialized_day(10, -4)

    assert_equal 1000, day.non_cash_inflows
    assert_equal 400, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer out of a holding with no price the day before is no flow" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [ { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 0, amount: 0 } ]
    )
    add_trade(account, qty: -10, price: 105)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end
  test "forward: a transfer the holdings don't show yet is no flow" do
    # The provider's snapshot still has the 10 shares on the day they leave,
    # so the holdings value doesn't change with the transfer.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 }
      ]
    )
    add_trade(account, qty: -10, price: 100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer in with no holding on the day it arrives is no flow" do
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [ { date: Date.current, ticker: "AAPL", qty: 10, price: 100, amount: 1000 } ]
    )
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end
  test "forward: transfers in and out at different prices on a day with none held are no flow" do
    # 5 in at 95 and 5 out at 100: valued at their own prices they would
    # leave 25 of market movement the holdings never show.
    account = forward_account_without_holdings
    add_trade(account, qty: 5, price: 95)
    add_trade(account, qty: -5, price: 100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a dividend booked as a trade doesn't make cancelling transfers a flow" do
    # A dividend trade moves no shares, so the 5 in and 5 out still cancel
    # out on a day with none held.
    account = forward_account_without_holdings
    add_trade(account, qty: 5, price: 95)
    add_trade(account, qty: -5, price: 100)
    account.entries.create!(
      name: "Dividend: AAPL", date: transfer_day, amount: -10, currency: "USD",
      entryable: Trade.new(qty: 0, price: 0, security: Security.find_by!(ticker: "AAPL"), currency: "USD", investment_activity_label: "Dividend")
    )

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  test "holding quantities are indexed only for securities with a priced transfer" do
    account = forward_account
    msft = Security.find_by!(ticker: "MSFT")
    account.holdings.create!(security: msft, date: transfer_day, qty: 5, price: 50, amount: 250, currency: "USD")
    add_trade(account, qty: 10, price: 95, label: "Buy")

    calculator = Balance::ForwardCalculator.new(account)
    calculator.calculate
    assert_nil calculator.send(:sync_cache).instance_variable_get(:@valued_holdings),
      "no priced transfer, so no index"

    add_trade(account, qty: 10, price: 95)
    calculator = Balance::ForwardCalculator.new(account)
    calculator.calculate
    indexed = calculator.send(:sync_cache).instance_variable_get(:@valued_holdings)
    assert_equal [ Security.find_by!(ticker: "AAPL").id ], indexed.keys
  end

  test "forward: a Kraken transfer priced at today's spot price for want of its own is no flow" do
    account = forward_account
    add_trade(account, qty: 10, price: 95, extra: { "kraken" => { "price_missing" => true } })

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 1000, day.net_market_flows
  end

  test "a depository account keeps its balance identity with a Transfer trade" do
    # Holdings don't make up a cash account's balance, so a transfer's value
    # is no flow there.
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [ { date: transfer_day, ticker: "AAPL", qty: 10, price: 100, amount: 1000 } ]
    )
    add_trade(account, qty: 10, price: 95)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)
    end_balance = day.start_cash_balance + day.start_non_cash_balance +
      (day.cash_inflows - day.cash_outflows) + (day.non_cash_inflows - day.non_cash_outflows) +
      day.net_market_flows + day.cash_adjustments + day.non_cash_adjustments

    assert_equal 0, day.non_cash_inflows
    assert_equal day.balance, end_balance
  end

  test "forward: a buy and a sale that net to nothing don't make cancelling transfers a flow" do
    account = forward_account_without_holdings
    add_trade(account, qty: 5, price: 95)
    add_trade(account, qty: -5, price: 100)
    add_cash_trade(account, qty: 1, amount: 100)
    add_cash_trade(account, qty: -1, amount: -100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 100, day.non_cash_inflows
    assert_equal 100, day.non_cash_outflows
    assert_equal 0, day.net_market_flows
  end

  # 10 shares at 100 become 20 at 50 on the transfer day.
  def split_account(transfer_qty:, end_qty:)
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: 10, price: 100, amount: 1000 },
        { date: transfer_day, ticker: "AAPL", qty: end_qty, price: 50, amount: end_qty * 50 },
        { date: Date.current, ticker: "AAPL", qty: end_qty, price: 50, amount: end_qty * 50 }
      ]
    )
    Security.find_by!(ticker: "AAPL").splits.create!(ex_date: transfer_day, numerator: 2, denominator: 1, source: "manual")
    add_trade(account, qty: transfer_qty, price: 50)
    account
  end

  test "forward: a split on the transfer day is not a transfer of the shares it adds" do
    account = split_account(transfer_qty: 10, end_qty: 20)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 0, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer in on the day of a split is a flow in post-split shares" do
    account = split_account(transfer_qty: 5, end_qty: 25)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 250, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a transfer in on the day of a split is valued at the post-split price, whatever price it was booked at" do
    account = split_account(transfer_qty: 5, end_qty: 25)
    account.entries.joins("INNER JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
      .find_each { |entry| entry.entryable.update!(price: 96) }

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 250, day.non_cash_inflows
    assert_equal 0, day.net_market_flows
  end

  test "forward: a split whose ratio doesn't divide the quantity evenly still shows a transfer" do
    # 3-for-2: 10 post-split shares were stored as 6.666666666666666667 the day before.
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ],
      holdings: [
        { date: 2.days.ago.to_date, ticker: "AAPL", qty: BigDecimal("6.666666666666666667"), price: 150, amount: 1000 },
        { date: transfer_day, ticker: "AAPL", qty: 15, price: 100, amount: 1500 },
        { date: Date.current, ticker: "AAPL", qty: 15, price: 100, amount: 1500 }
      ]
    )
    Security.find_by!(ticker: "AAPL").splits.create!(ex_date: transfer_day, numerator: 3, denominator: 2, source: "manual")
    add_trade(account, qty: 5, price: 100)

    day = flows_on(Balance::ForwardCalculator.new(account).calculate, transfer_day)

    assert_equal 500, day.non_cash_inflows
  end

  def add_cash_trade(account, qty:, amount:)
    trade = Trade.new(qty: qty, security: Security.find_by!(ticker: "AAPL"), price: 100, currency: "USD")
    account.entries.create!(name: "Trade", date: transfer_day, amount: amount, currency: "USD", entryable: trade)
  end

  def forward_account_without_holdings
    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [ { type: "opening_anchor", date: 3.days.ago.to_date, balance: 5000 } ]
    )
    Security.find_or_create_by!(ticker: "AAPL") { |security| security.name = "AAPL" }
    account
  end
end
