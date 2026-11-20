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

  # Each keeps IBKR's sign: negative there is money out, positive in Sure.
  test "processor imports withholding tax, interest, fees and payments in lieu" do
    set_cash_transactions(
      cash_row("5001", "Withholding Tax", "-0.38", conid: "265598"),
      cash_row("5002", "Withholding Tax", "0.10", conid: "265598"),
      cash_row("5003", "Payment In Lieu Of Dividends", "1.20", conid: "265598"),
      cash_row("5004", "Broker Interest Received", "1.00"),
      cash_row("5005", "Broker Interest Paid", "-2.00"),
      cash_row("5006", "Bond Interest Received", "3.00"),
      cash_row("5007", "Bond Interest Paid", "-0.50"),
      cash_row("5008", "Other Fees", "-10.00"),
      cash_row("5009", "Commission Adjustments", "0.25"),
      cash_row("5010", "Withholding Tax", "-0.20")
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    expected = {
      "5001" => [ "Dividend", "0.38", "Withholding Tax for #{securities(:aapl).ticker}" ],
      "5002" => [ "Dividend", "-0.10", "Withholding Tax for #{securities(:aapl).ticker}" ],
      "5003" => [ "Dividend", "-1.20", "Payment In Lieu Of Dividends for #{securities(:aapl).ticker}" ],
      "5004" => [ "Interest", "-1.00", "Broker Interest Received" ],
      "5005" => [ "Interest", "2.00", "Broker Interest Paid" ],
      "5006" => [ "Interest", "-3.00", "Bond Interest Received" ],
      "5007" => [ "Interest", "0.50", "Bond Interest Paid" ],
      "5008" => [ "Fee", "10.00", "Other Fees" ],
      "5009" => [ "Fee", "-0.25", "Commission Adjustments" ],
      "5010" => [ "Interest", "0.20", "Withholding Tax" ]
    }

    expected.each do |transaction_id, (label, amount, name)|
      entry = @account.entries.find_by(external_id: "ibkr_cash_#{transaction_id}")
      assert_not_nil entry, "cash transaction #{transaction_id} was not imported"
      assert_equal label, entry.entryable.investment_activity_label, transaction_id
      assert_equal BigDecimal(amount), entry.amount, transaction_id
      assert_equal name, entry.name, transaction_id
      assert_equal "USD", entry.currency, transaction_id
    end

    withholding = @account.entries.find_by(external_id: "ibkr_cash_5001").entryable
    assert_equal securities(:aapl).id, withholding.extra["security_id"]
    assert_equal "Withholding Tax", withholding.extra.dig("ibkr", "type")
  end

  # Trade Republic books dividends net of the tax withheld; IBKR reports the
  # tax as a row of its own, which nets into the dividend through its label.
  test "withholding tax reduces dividend income" do
    set_cash_transactions(
      cash_row("6101", "Dividends", "2.50", conid: "265598"),
      cash_row("6102", "Withholding Tax", "-0.38", conid: "265598")
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    totals = InvestmentStatement::Totals.new(@family, account_ids: [ @account.id ], date_range: Date.current..Date.current).call
    assert_equal BigDecimal("2.12"), totals[:dividends]
  end

  # IBKR cancels a dividend with a negative Dividends row and books it again,
  # so the reversal is money out and the income nets to the rebooked amount.
  test "a dividend reversal is booked as money out" do
    set_cash_transactions(
      cash_row("6001", "Dividends", "2.50", conid: "265598"),
      cash_row("6002", "Dividends", "-2.50", conid: "265598"),
      cash_row("6003", "Dividends", "2.40", conid: "265598")
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    amounts = %w[6001 6002 6003].map { |id| @account.entries.find_by(external_id: "ibkr_cash_#{id}").amount }
    assert_equal [ BigDecimal("-2.5"), BigDecimal("2.5"), BigDecimal("-2.4") ], amounts

    totals = InvestmentStatement::Totals.new(@family, account_ids: [ @account.id ], date_range: Date.current..Date.current).call
    assert_equal BigDecimal("2.4"), totals[:dividends]
  end

  test "an unsupported cash transaction type is skipped" do
    set_cash_transactions(cash_row("7001", "Price Adjustments", "-1.00"))

    assert_nothing_raised { IbkrAccount::Processor.new(@ibkr_account).process }

    assert_nil @account.entries.find_by(external_id: "ibkr_cash_7001")
  end

  # A skipped row with an amount is cash the account lost track of, so support
  # needs to see it; one entry per run, not one per row.
  test "skipped cash transaction types with an amount are captured for support" do
    set_cash_transactions(
      cash_row("7101", "Price Adjustments", "-1.00"),
      cash_row("7102", "Price Adjustments", "-2.00"),
      cash_row("7103", "Advisor Fees", "-3.00"),
      cash_row("7104", "Something Else", "0")
    )

    assert_difference -> { DebugLogEntry.where(provider_key: "ibkr").count }, 1 do
      IbkrAccount::Processor.new(@ibkr_account).process
    end

    entry = DebugLogEntry.where(provider_key: "ibkr").last
    assert_equal "warn", entry.level
    assert_equal @family, entry.family
    assert_equal @ibkr_account.account_provider, entry.account_provider
    assert_equal({ "Price Adjustments" => 2, "Advisor Fees" => 1 }, entry.metadata["skipped_cash_transaction_types"])
  end

  # Tax withheld from a bond coupon carries the bond's conid, but it reduces
  # the coupon's interest, not dividends.
  test "withholding tax on a bond coupon reduces interest" do
    set_cash_transactions(
      cash_row("6201", "Bond Interest Received", "3.00", conid: "9001"),
      cash_row("6202", "Withholding Tax", "-0.30", conid: "9001"),
      cash_row("6203", "Withholding Tax", "-0.10", conid: "9002", asset_category: "BOND")
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_equal "Interest", @account.entries.find_by(external_id: "ibkr_cash_6202").entryable.investment_activity_label
    assert_equal "Interest", @account.entries.find_by(external_id: "ibkr_cash_6203").entryable.investment_activity_label

    totals = InvestmentStatement::Totals.new(@family, account_ids: [ @account.id ], date_range: Date.current..Date.current).call
    assert_equal BigDecimal("0"), totals[:dividends]
    assert_equal BigDecimal("2.60"), totals[:interest]
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

    def cash_row(transaction_id, type, amount, conid: nil, asset_category: nil)
      {
        "transaction_id" => transaction_id,
        "type" => type,
        "amount" => amount,
        "currency" => "USD",
        "fx_rate_to_base" => "1",
        "report_date" => Date.current.to_s,
        "conid" => conid,
        "asset_category" => asset_category
      }.compact
    end

    def set_cash_transactions(*rows)
      payload = @ibkr_account.reload.raw_activities_payload.deep_dup
      payload["cash_transactions"] = rows
      @ibkr_account.update!(raw_activities_payload: payload)
    end

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
