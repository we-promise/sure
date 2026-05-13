require "test_helper"

class IbkrAccountProcessorTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :accounts, :securities

  setup do
    @family = families(:dylan_family)
    @ibkr_account = ibkr_accounts(:main_account)

    @account = @family.accounts.create!(
      name: "IBKR Investment",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account.ensure_account_provider!(@account)
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "10",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "125.50",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ],
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1001",
            "transaction_id" => "1001a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "2",
            "trade_price" => "140.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.90",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s,
            "ib_commission" => "-1.25",
            "ib_commission_currency" => "USD"
          },
          {
            "asset_category" => "STK",
            "trade_id" => "1002",
            "transaction_id" => "1002a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "-1",
            "trade_price" => "155.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.92",
            "buy_sell" => "SELL",
            "trade_date" => Date.current.to_s,
            "ib_commission" => "-1.10",
            "ib_commission_currency" => "USD"
          }
        ],
        cash_transactions: [
          {
            "transaction_id" => "4001",
            "type" => "Deposits/Withdrawals",
            "amount" => "500.00",
            "currency" => "CHF",
            "fx_rate_to_base" => "1",
            "report_date" => Date.current.to_s
          },
          {
            "transaction_id" => "4002",
            "type" => "Dividends",
            "amount" => "2.50",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "report_date" => Date.current.to_s,
            "conid" => "265598"
          }
        ]
      },
      report_date: Date.current,
      current_balance: BigDecimal("3351.00"),
      cash_balance: BigDecimal("1000.50"),
      currency: "CHF"
    )
  end

  test "processor imports holdings, trades, cash transactions, and commissions" do
    IbkrAccount::Processor.new(@ibkr_account).process

    @account.reload
    assert_equal BigDecimal("3351.00"), @account.balance
    assert_equal BigDecimal("1000.50"), @account.cash_balance
    assert_equal "CHF", @account.currency

    holding = @account.holdings.find_by(security: securities(:aapl), date: Date.current)
    assert_not_nil holding
    assert_equal BigDecimal("10"), holding.qty
    assert_equal BigDecimal("150.00"), holding.price
    assert_equal BigDecimal("125.50"), holding.cost_basis
    assert_equal "USD", holding.currency

    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    sell_trade = @account.entries.find_by(external_id: "ibkr_trade_1002")
    assert_not_nil buy_trade
    assert_not_nil sell_trade
    assert_equal "Buy", buy_trade.entryable.investment_activity_label
    assert_equal "Sell", sell_trade.entryable.investment_activity_label
    assert_equal BigDecimal("2"), buy_trade.entryable.qty
    assert_equal BigDecimal("-1"), sell_trade.entryable.qty
    assert_equal BigDecimal("280.0"), buy_trade.amount
    assert_equal BigDecimal("-155.0"), sell_trade.amount
    assert_equal "USD", buy_trade.currency
    assert_equal "USD", sell_trade.currency
    assert_equal 0.9, buy_trade.entryable.exchange_rate
    assert_equal 0.92, sell_trade.entryable.exchange_rate

    dividend = @account.entries.find_by(external_id: "ibkr_cash_4002")
    assert_not_nil dividend
    assert_equal "Dividend", dividend.entryable.investment_activity_label
    assert_equal BigDecimal("-2.5"), dividend.amount
    assert_equal securities(:aapl).id, dividend.entryable.extra["security_id"]

    commission_one = @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    commission_two = @account.entries.find_by(external_id: "ibkr_trade_fee_1002")
    assert_not_nil commission_one
    assert_not_nil commission_two
    assert_equal BigDecimal("1.25"), commission_one.amount
    assert_equal BigDecimal("1.1"), commission_two.amount
    assert_equal "USD", commission_one.currency
    assert_equal "USD", commission_two.currency
    assert_equal securities(:aapl).id, commission_one.entryable.extra["security_id"]
    assert_equal securities(:aapl).id, commission_two.entryable.extra["security_id"]

    deposit = @account.entries.find_by(external_id: "ibkr_cash_4001")

    assert_not_nil deposit
    assert_equal "Contribution", deposit.entryable.investment_activity_label
    assert_equal BigDecimal("-500"), deposit.amount
    assert_equal "CHF", deposit.currency

    assert_equal "USD", dividend.currency
  end

  test "processor computes weighted provider cost basis for grouped lots" do
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "10",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "125.50",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        },
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "20",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "122.00",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ]
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    holding = @account.holdings.find_by(security: securities(:aapl), date: Date.current)

    assert_not_nil holding
    assert_equal BigDecimal("30"), holding.qty
    assert_equal BigDecimal("123.1667"), holding.cost_basis
  end

  test "processor repairs default opening anchor after importing activity entries" do
    result = Account::OpeningBalanceManager.new(@account).set_opening_balance(
      balance: @ibkr_account.current_balance,
      date: 2.years.ago.to_date
    )

    assert result.success?

    opening_anchor = @account.valuations.opening_anchor.includes(:entry).first
    assert_not_nil opening_anchor
    assert_equal @ibkr_account.current_balance.to_d, opening_anchor.entry.amount.to_d

    IbkrAccount::Processor.new(@ibkr_account).process

    opening_anchor.reload
    assert_equal BigDecimal("0"), opening_anchor.entry.amount.to_d
  end

  test "processor imports commission-free trades without creating fee entries" do
    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1003",
            "transaction_id" => "1003a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "3",
            "trade_price" => "145.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s
          }
        ],
        cash_transactions: []
      }
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    trade = @account.entries.find_by(external_id: "ibkr_trade_1003")
    fee = @account.entries.find_by(external_id: "ibkr_trade_fee_1003")

    assert_not_nil trade
    assert_equal BigDecimal("3"), trade.entryable.qty
    assert_equal BigDecimal("435.0"), trade.amount
    assert_equal "USD", trade.currency
    assert_nil fee
  end

  test "processor logs and falls back to current date for invalid trade_date" do
    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1004",
            "transaction_id" => "1004a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "1",
            "trade_price" => "146.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "buy_sell" => "BUY",
            "trade_date" => "not-a-date"
          }
        ],
        cash_transactions: []
      }
    )

    Rails.logger.expects(:warn).with do |message|
      message.include?("IbkrAccount::DataHelpers - Missing or invalid trade_date") &&
        message.include?("1004")
    end

    IbkrAccount::Processor.new(@ibkr_account).process

    trade = @account.entries.find_by(external_id: "ibkr_trade_1004")

    assert_not_nil trade
    assert_equal Date.current, trade.date
  end
end
