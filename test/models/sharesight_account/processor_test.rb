require "test_helper"

class SharesightAccount::ProcessorTest < ActiveSupport::TestCase
  HOLDINGS = [
    { "id" => 1, "quantity" => 100.0, "value" => 10500.0, "instrument_price" => 105.0,
      "instrument" => { "code" => "VAS", "market_code" => "ASX", "name" => "Vanguard Australian Shares", "currency_code" => "AUD" },
      "instrument_currency" => { "code" => "AUD" } },
    { "id" => 2, "quantity" => 10.0, "value" => 4500.0, "instrument_price" => 290.0,
      "instrument" => { "code" => "AAPL", "market_code" => "NASDAQ", "currency_code" => "USD" },
      "instrument_currency" => { "code" => "USD" } },
    { "id" => 3, "quantity" => 0.0, "value" => 0.0, "instrument_price" => 40.0,
      "instrument" => { "code" => "OLD", "market_code" => "ASX", "currency_code" => "AUD" } },
    { "id" => 4, "quantity" => 5.0, "limited" => true, "instrument" => { "code" => "HIDDEN", "market_code" => "ASX" } },
    # Sharesight treats the coin as its own currency. Price and value are in AUD.
    { "id" => 5, "quantity" => 0.25, "value" => 29091.85, "instrument_price" => 116367.39,
      "instrument" => { "code" => "BTC", "market_code" => "CRYPTO", "currency_code" => "BTC" },
      "instrument_currency" => { "code" => "BTC" } }
  ].freeze

  TRADES = [
    { "id" => 100, "transaction_type" => "OPENING_BALANCE", "transaction_date" => "2021-02-03", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 90, "price" => nil, "cost_base" => 8100.0, "exchange_rate" => 1.0, "brokerage" => 0, "holding_id" => 1, "state" => "confirmed" },
    { "id" => 101, "transaction_type" => "BUY", "transaction_date" => "2025-06-02", "symbol" => "AAPL", "market" => "NASDAQ",
      "quantity" => 10, "price" => 200.0, "exchange_rate" => 0.65, "brokerage" => 10.0, "brokerage_currency_code" => "AUD",
      "holding_id" => 2, "state" => "confirmed" },
    { "id" => 102, "transaction_type" => "SPLIT", "transaction_date" => "2025-07-01", "symbol" => "AAPL", "market" => "NASDAQ",
      "quantity" => 10, "price" => 0, "holding_id" => 2, "state" => "confirmed" },
    { "id" => 103, "transaction_type" => "SELL", "transaction_date" => "2025-08-01", "symbol" => "OLD", "market" => "ASX",
      "quantity" => -50, "price" => 40.0, "exchange_rate" => 1.0, "brokerage" => 9.5, "holding_id" => 3, "state" => "confirmed" },
    { "id" => nil, "transaction_type" => "BUY", "transaction_date" => "2026-01-15", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 2, "price" => 99.0, "exchange_rate" => 1.0, "holding_id" => 1, "state" => "unconfirmed" },
    { "id" => 105, "transaction_type" => "BUY", "transaction_date" => "2015-12-01", "symbol" => "BTC", "market" => "CRYPTO",
      "quantity" => 0.25, "price" => 1.0, "exchange_rate" => 0.002, "brokerage" => 0.0, "brokerage_currency_code" => "AUD",
      "holding_id" => 5, "state" => "confirmed" },
    { "id" => 106, "transaction_type" => "CAPITAL_RETURN", "transaction_date" => "2025-11-05", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 0.0, "price" => 0.0, "value" => -34.5, "capital_return_value" => 34.5, "holding_id" => 1, "state" => "confirmed" }
  ].freeze

  PAYOUTS = [
    { "id" => 500, "symbol" => "VAS", "market" => "ASX", "paid_on" => "2026-01-15", "amount" => 120.0, "currency" => "AUD",
      "holding_id" => 1, "state" => "confirmed",
      "drp_trade_attributes" => { "dividend_reinvested" => true, "quantity" => 1.0, "price" => 98.0 } },
    { "id" => nil, "symbol" => "VAS", "market" => "ASX", "paid_on" => "2026-04-15", "amount" => 95.0, "currency" => "AUD",
      "holding_id" => 1, "state" => "unconfirmed" }
  ].freeze

  CASH_TRANSACTIONS = [
    { "id" => 900, "date_time" => "2021-02-01T00:00:00Z", "amount" => 10000, "description" => "Initial funding",
      "cash_account_transaction_type" => { "name" => "DEPOSIT" }, "currency" => "AUD" },
    { "id" => 901, "date_time" => "2025-06-02T00:00:00Z", "amount" => -1316.88, "trade_id" => 101,
      "cash_account_transaction_type" => { "name" => "TRADE" }, "currency" => "AUD" },
    { "id" => 902, "date_time" => "2026-03-01T00:00:00Z", "amount" => -500, "cash_account_transaction_type" => { "name" => "WITHDRAWAL" },
      "currency" => "AUD" },
    { "id" => 903, "date_time" => "2026-03-31T00:00:00Z", "amount" => 1.23, "cash_account_transaction_type" => { "name" => "INTEREST" },
      "currency" => "AUD" }
  ].freeze

  setup do
    @family = families(:dylan_family)
    item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @sharesight_account = item.sharesight_accounts.create!(
      name: "Shares",
      sharesight_account_id: "42",
      currency: "AUD",
      current_balance: 44342.35,
      cash_balance: 250.5,
      raw_holdings_payload: HOLDINGS,
      raw_trades_payload: TRADES,
      raw_payouts_payload: PAYOUTS,
      raw_cash_transactions_payload: CASH_TRANSACTIONS
    )
    @account = @family.accounts.create!(name: "Shares", balance: 0, cash_balance: 0, currency: "AUD", accountable: Investment.new)
    @sharesight_account.ensure_account_provider!(@account)

    # Already in the DB, so the resolver doesn't go searching a price provider.
    %w[VAS OLD].each do |ticker|
      Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: "XASX")
    end
  end

  test "sets the balance from Sharesight's portfolio value and cash" do
    process

    @account.reload
    assert_equal BigDecimal("44342.35"), @account.balance
    assert_equal BigDecimal("250.5"), @account.cash_balance
  end

  test "imports held units at Sharesight's price in each instrument's currency" do
    process

    holdings = @account.holdings.where(date: Date.current).includes(:security).to_h do |holding|
      [ holding.security.ticker, [ holding.qty, holding.price, holding.currency ] ]
    end
    assert_equal({
      "VAS" => [ BigDecimal("100"), BigDecimal("105"), "AUD" ],
      "AAPL" => [ BigDecimal("10"), BigDecimal("290"), "USD" ],
      "BTC" => [ BigDecimal("0.25"), BigDecimal("116367.4"), "AUD" ]
    }, holdings)
    assert_equal "XNAS", @account.holdings.joins(:security).find_by(securities: { ticker: "AAPL" }).security.exchange_operating_mic
  end

  test "books buys, sells and opening balances, skipping splits" do
    result = process

    assert_equal 5, result[:trades]

    opening = trade("sharesight_trade_100")
    assert_equal [ BigDecimal("90"), BigDecimal("90"), "AUD", BigDecimal("8100"), "Buy" ],
                 [ opening.entryable.qty, opening.entryable.price, opening.currency, opening.amount, opening.entryable.investment_activity_label ]

    sell = trade("sharesight_trade_103")
    assert_equal [ BigDecimal("-50"), BigDecimal("9.5"), BigDecimal("-1990.5"), "Sell" ],
                 [ sell.entryable.qty, sell.entryable.fee, sell.amount, sell.entryable.investment_activity_label ]

    assert_nil @account.entries.find_by(external_id: "sharesight_trade_102")
  end

  test "a foreign trade is booked in its own currency with the fee and rate converted" do
    process

    buy = trade("sharesight_trade_101")
    # 10 AUD of brokerage at 0.65 USD per AUD.
    assert_equal [ "USD", BigDecimal("200"), BigDecimal("6.5"), BigDecimal("2006.5") ],
                 [ buy.currency, buy.entryable.price, buy.entryable.fee, buy.amount ]
    assert_in_delta 1 / 0.65, buy.entryable.exchange_rate, 1e-9
  end

  test "crypto is booked in the portfolio's currency" do
    process

    # Priced at 1 BTC, at 0.002 BTC per AUD, so A$500 each.
    bitcoin = trade("sharesight_trade_105")
    assert_equal [ "AUD", BigDecimal("500"), BigDecimal("125") ], [ bitcoin.currency, bitcoin.entryable.price, bitcoin.amount ]
    assert_nil bitcoin.entryable.exchange_rate
  end

  test "a reinvested dividend is income and a reinvestment trade" do
    result = process

    assert_equal 2, result[:dividends]
    dividend = @account.entries.find_by!(external_id: "sharesight_payout_500")
    assert_equal [ BigDecimal("-120"), "Dividend from VAS", "Dividend" ],
                 [ dividend.amount, dividend.name, dividend.entryable.investment_activity_label ]

    drp = trade("sharesight_drp_500")
    assert_equal [ BigDecimal("1"), BigDecimal("98"), "Reinvestment" ],
                 [ drp.entryable.qty, drp.entryable.price, drp.entryable.investment_activity_label ]
  end

  test "a reinvestment Sharesight also records as a trade isn't booked twice" do
    allotment = { "id" => nil, "transaction_type" => "BUY", "transaction_date" => "2026-01-15", "symbol" => "VAS", "market" => "ASX",
                  "quantity" => 1, "price" => 98.0, "exchange_rate" => 1.0, "holding_id" => 1, "state" => "unconfirmed" }
    @sharesight_account.update!(raw_trades_payload: TRADES + [ allotment ])

    process

    assert trade("sharesight_unconfirmed_trade_1_2026-01-15_BUY_1.0")
    assert_nil @account.entries.find_by(external_id: "sharesight_drp_500")
  end

  test "unconfirmed records are booked provisionally until Sharesight confirms them" do
    process

    assert trade("sharesight_unconfirmed_trade_1_2026-01-15_BUY_2.0")
    provisional = @account.entries.find_by!(external_id: "sharesight_unconfirmed_payout_1_2026-04-15")
    assert_equal BigDecimal("-95"), provisional.amount

    confirmed_trades = TRADES.map { |t| t["id"].nil? ? t.merge("id" => 104, "state" => "confirmed") : t }
    confirmed_payouts = PAYOUTS.map { |p| p["id"].nil? ? p.merge("id" => 501, "state" => "confirmed") : p }
    @sharesight_account.update!(raw_trades_payload: confirmed_trades, raw_payouts_payload: confirmed_payouts)
    process

    assert_empty @account.entries.where("external_id LIKE 'sharesight_unconfirmed_%'")
    assert_equal BigDecimal("2"), trade("sharesight_trade_104").entryable.qty
    assert_equal BigDecimal("-95"), @account.entries.find_by!(external_id: "sharesight_payout_501").amount
  end

  test "unconfirmed records dated after today wait until they happen" do
    announced = { "id" => nil, "symbol" => "VAS", "market" => "ASX", "paid_on" => (Date.current + 10).iso8601, "amount" => 80.0,
                  "currency" => "AUD", "holding_id" => 1, "state" => "unconfirmed" }
    @sharesight_account.update!(raw_payouts_payload: PAYOUTS + [ announced ])

    process

    assert_nil @account.entries.find_by(date: Date.current + 10)
  end

  test "a capital return is booked as cash" do
    process

    capital_return = @account.entries.find_by!(external_id: "sharesight_capital_return_106")
    assert_equal [ BigDecimal("-34.5"), "Capital return from VAS", "Other", "Transaction" ],
                 [ capital_return.amount, capital_return.name, capital_return.entryable.investment_activity_label, capital_return.entryable_type ]
  end

  test "a foreign capital return is booked at its value in the portfolio's currency" do
    foreign = { "id" => 107, "transaction_type" => "CAPITAL_RETURN", "transaction_date" => "2025-09-01", "symbol" => "AAPL", "market" => "NASDAQ",
                "quantity" => 0.0, "price" => 0.0, "value" => -65.0, "capital_return_value" => 42.25, "holding_id" => 2, "state" => "confirmed" }
    @sharesight_account.update!(raw_trades_payload: TRADES + [ foreign ])

    process

    capital_return = @account.entries.find_by!(external_id: "sharesight_capital_return_107")
    assert_equal [ BigDecimal("-65"), "AUD" ], [ capital_return.amount, capital_return.currency ]
  end

  test "cash account movements are booked, leaving out the cash legs of trades" do
    result = process

    assert_equal 4, result[:transactions]
    cash = @account.entries.where("external_id LIKE 'sharesight_cash_%'").order(:date).map do |entry|
      [ entry.external_id, entry.amount, entry.entryable.investment_activity_label ]
    end
    assert_equal [
      [ "sharesight_cash_900", BigDecimal("-10000"), "Contribution" ],
      [ "sharesight_cash_902", BigDecimal("500"), "Withdrawal" ],
      [ "sharesight_cash_903", BigDecimal("-1.23"), "Interest" ]
    ], cash
  end

  test "processing again updates entries instead of duplicating them" do
    process
    count = @account.entries.count

    process

    assert_equal count, @account.entries.reload.count
  end

  private

    def process
      SharesightAccount::Processor.new(@sharesight_account.reload).process
    end

    def trade(external_id)
      @account.entries.find_by!(external_id: external_id, entryable_type: "Trade")
    end
end
