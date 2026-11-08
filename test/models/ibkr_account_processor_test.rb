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

  test "processor imports holdings, trades with their commissions, and cash transactions" do
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
    # The commission is part of the trade: in its fee, and in the cash it
    # moved -- on top of a buy, off a sell's proceeds.
    assert_equal BigDecimal("1.25"), buy_trade.entryable.fee
    assert_equal BigDecimal("1.1"), sell_trade.entryable.fee
    assert_equal BigDecimal("281.25"), buy_trade.amount
    assert_equal BigDecimal("-153.9"), sell_trade.amount
    assert_equal "USD", buy_trade.currency
    assert_equal "USD", sell_trade.currency
    assert_equal 0.9, buy_trade.entryable.exchange_rate
    assert_equal 0.92, sell_trade.entryable.exchange_rate

    dividend = @account.entries.find_by(external_id: "ibkr_cash_4002")
    assert_not_nil dividend
    assert_equal "Dividend", dividend.entryable.investment_activity_label
    assert_equal BigDecimal("-2.5"), dividend.amount
    assert_equal securities(:aapl).id, dividend.entryable.extra["security_id"]

    assert_nil @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    assert_nil @account.entries.find_by(external_id: "ibkr_trade_fee_1002")

    deposit = @account.entries.find_by(external_id: "ibkr_cash_4001")

    assert_not_nil deposit
    assert_equal "Contribution", deposit.entryable.investment_activity_label
    assert_equal BigDecimal("-500"), deposit.amount
    assert_equal "CHF", deposit.currency

    assert_equal "USD", dividend.currency
  end

  # `trades.fee` is in the trade's currency, so a commission IBKR charged in
  # another one stays a transaction of its own.
  test "a commission in another currency stays a separate transaction" do
    set_commission_currency("1001", "CHF")

    IbkrAccount::Processor.new(@ibkr_account).process

    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    assert_equal 0, buy_trade.entryable.fee
    assert_equal BigDecimal("280.0"), buy_trade.amount

    commission = @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    assert_equal BigDecimal("1.25"), commission.amount
    assert_equal "CHF", commission.currency
    assert_equal securities(:aapl).id, commission.entryable.extra["security_id"]
  end

  # With no currency stated, the separate entry has always taken the account's,
  # so the commission is not assumed to be in the trade's.
  test "a commission with no currency stays a separate transaction" do
    set_commission_currency("1001", nil)

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_equal 0, @account.entries.find_by(external_id: "ibkr_trade_1001").entryable.fee
    assert_equal "CHF", @account.entries.find_by(external_id: "ibkr_trade_fee_1001").currency
  end

  # Imported before the commission moved onto the trade, the separate entry
  # would now count it twice.
  test "a commission imported as its own transaction moves onto the trade" do
    import_legacy_commission("1001", "1.25")

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_nil @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    assert_equal BigDecimal("1.25"), buy_trade.entryable.fee
    assert_equal BigDecimal("281.25"), buy_trade.amount
  end

  test "a separate commission the user edited is left alone, and not counted twice" do
    legacy = import_legacy_commission("1001", "1.25")
    legacy.update!(user_modified: true)

    IbkrAccount::Processor.new(@ibkr_account).process

    assert legacy.reload.persisted?
    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    assert_equal 0, buy_trade.entryable.fee
    assert_equal BigDecimal("280.0"), buy_trade.amount
  end

  # A receipt does not mark the entry modified, and deleting the entry would
  # delete the receipt with it.
  test "a separate commission with a receipt attached is left alone" do
    legacy = import_legacy_commission("1001", "1.25")
    legacy.entryable.attachments.attach(io: StringIO.new("receipt"), filename: "receipt.pdf", content_type: "application/pdf")

    IbkrAccount::Processor.new(@ibkr_account).process

    assert legacy.reload.entryable.attachments.attached?
    assert_equal 0, @account.entries.find_by(external_id: "ibkr_trade_1001").entryable.fee
  end

  # An API edit without the user-modified flag still locks what it changed.
  test "a separate commission edited through the API is left alone" do
    legacy = import_legacy_commission("1001", "1.25")
    legacy.update!(notes: "billed twice, disputed")
    legacy.lock_saved_attributes!

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_equal "billed twice, disputed", legacy.reload.notes
    assert_equal 0, @account.entries.find_by(external_id: "ibkr_trade_1001").entryable.fee
  end

  # Auto-categorization locks the category too, so that lock alone is not the
  # user's, or no commission would ever move onto its trade.
  test "a separate commission only auto-categorized still moves onto the trade" do
    legacy = import_legacy_commission("1001", "1.25")
    legacy.entryable.lock_attr!(:category_id)

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_nil @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    assert_equal BigDecimal("1.25"), @account.entries.find_by(external_id: "ibkr_trade_1001").entryable.fee
  end

  # The import rewrites an edited trade, but it never wrote a fee before, so it
  # must not start overwriting one the user set. The cash follows that fee.
  test "a trade whose fee the user edited keeps it" do
    IbkrAccount::Processor.new(@ibkr_account).process
    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    buy_trade.entryable.update!(fee: 3)
    buy_trade.update!(user_modified: true)

    IbkrAccount::Processor.new(@ibkr_account.reload).process

    buy_trade.reload
    assert_equal 3, buy_trade.entryable.fee
    assert_equal BigDecimal("283.0"), buy_trade.amount
    assert_nil @account.entries.find_by(external_id: "ibkr_trade_fee_1001"), "the commission is not counted again beside it"
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
    assert_in_delta BigDecimal("123.1667"), holding.cost_basis, BigDecimal("0.0001")
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

  private

    def set_commission_currency(trade_id, currency)
      payload = @ibkr_account.reload.raw_activities_payload.deep_dup
      payload["trades"].find { |trade| trade["trade_id"] == trade_id }["ib_commission_currency"] = currency
      @ibkr_account.update!(raw_activities_payload: payload)
    end

    def import_legacy_commission(trade_id, amount)
      Account::ProviderImportAdapter.new(@account).import_transaction(
        external_id: "ibkr_trade_fee_#{trade_id}",
        amount: BigDecimal(amount),
        currency: "USD",
        date: Date.current,
        name: "Trade Commission for AAPL",
        source: "ibkr",
        investment_activity_label: "Fee"
      )
    end
end
