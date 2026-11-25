require "test_helper"

class TinkoffInvestAccount::ProcessorTest < ActiveSupport::TestCase
  PORTFOLIO = {
    "totalAmountPortfolio" => { "currency" => "rub", "units" => "1600000", "nano" => 0 },
    "totalAmountCurrencies" => { "currency" => "rub", "units" => "116100", "nano" => 0 },
    "positions" => [
      {
        "figi" => "BBG004730N88",
        "instrumentUid" => "uid-sber",
        "instrumentType" => "share",
        "quantity" => { "units" => "5000", "nano" => 0 },
        "currentPrice" => { "currency" => "rub", "units" => "260", "nano" => 0 },
        "averagePositionPrice" => { "currency" => "rub", "units" => "240", "nano" => 500_000_000 },
        "resolved_instrument" => {
          "ticker" => "SBER",
          "name" => "Sberbank",
          "exchange_operating_mic" => "MISX",
          "country_code" => "RU",
          "logo_url" => "https://invest-brands.cdn-tinkoff.ru/SBERx160.png"
        }
      },
      {
        "figi" => "BBG011FHFN80",
        "instrumentUid" => "uid-ofz26238",
        "instrumentType" => "bond",
        "quantity" => { "units" => "200", "nano" => 0 },
        "currentPrice" => { "currency" => "rub", "units" => "550", "nano" => 0 },
        "currentNkd" => { "currency" => "rub", "units" => "18", "nano" => 500_000_000 },
        "averagePositionPrice" => { "currency" => "rub", "units" => "590", "nano" => 0 },
        "resolved_instrument" => {
          "ticker" => "SU26238RMFS4",
          "name" => "OFZ 26238",
          "exchange_operating_mic" => "MISX",
          "country_code" => "RU",
          "nominal" => "1000.0",
          "amortization_flag" => false
        }
      },
      {
        "figi" => "RUB000UTSTOM",
        "instrumentUid" => "uid-rub",
        "instrumentType" => "currency",
        "ticker" => "RUB",
        "quantity" => { "units" => "116100", "nano" => 0 },
        "currentPrice" => { "currency" => "rub", "units" => "1", "nano" => 0 }
      }
    ]
  }.freeze

  OPERATIONS = [
    {
      "id" => "op-in-1",
      "date" => "2024-02-10T10:00:00Z",
      "type" => "OPERATION_TYPE_INPUT",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "1000000", "nano" => 0 },
      "description" => "Brokerage deposit"
    },
    {
      "id" => "op-buy-1",
      "date" => "2024-02-12T11:15:00Z",
      "type" => "OPERATION_TYPE_BUY",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-sber",
      "quantity" => "6000",
      "price" => { "currency" => "rub", "units" => "240", "nano" => 500_000_000 },
      "payment" => { "currency" => "rub", "units" => "-1443000", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-fee-1",
      "date" => "2024-02-12T11:15:01Z",
      "type" => "OPERATION_TYPE_BROKER_FEE",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "-721", "nano" => -500_000_000 },
      "name" => "Broker commission"
    },
    {
      "id" => "op-div-1",
      "date" => "2024-07-15T09:00:00Z",
      "type" => "OPERATION_TYPE_DIVIDEND",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-sber",
      "payment" => { "currency" => "rub", "units" => "199800", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-tax-1",
      "date" => "2024-07-15T09:00:01Z",
      "type" => "OPERATION_TYPE_DIVIDEND_TAX",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-sber",
      "payment" => { "currency" => "rub", "units" => "-25974", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-tax-refund-1",
      "date" => "2024-08-01T09:00:00Z",
      "type" => "OPERATION_TYPE_TAX_REFUND",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "500", "nano" => 0 }
    },
    {
      "id" => "op-sell-1",
      "date" => "2025-03-20T12:00:00Z",
      "type" => "OPERATION_TYPE_SELL",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-sber",
      "quantity" => "1000",
      "price" => { "currency" => "rub", "units" => "280", "nano" => 0 },
      "payment" => { "currency" => "rub", "units" => "280000", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-coupon-1",
      "date" => "2025-05-01T09:00:00Z",
      "type" => "OPERATION_TYPE_COUPON",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-ofz26238",
      "payment" => { "currency" => "rub", "units" => "7080", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SU26238RMFS4", "name" => "OFZ 26238", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-amort-1",
      "date" => "2025-05-02T09:00:00Z",
      "type" => "OPERATION_TYPE_BOND_REPAYMENT",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-ofz26238",
      "quantity" => "0",
      "payment" => { "currency" => "rub", "units" => "5000", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SU26238RMFS4", "name" => "OFZ 26238", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-repay-full-1",
      "date" => "2025-06-01T09:00:00Z",
      "type" => "OPERATION_TYPE_BOND_REPAYMENT_FULL",
      "state" => "OPERATION_STATE_EXECUTED",
      "instrumentUid" => "uid-ofz26238",
      "quantity" => "10",
      "price" => { "currency" => "rub", "units" => "1000", "nano" => 0 },
      "payment" => { "currency" => "rub", "units" => "10000", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SU26238RMFS4", "name" => "OFZ 26238", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    },
    {
      "id" => "op-out-1",
      "date" => "2025-06-05T10:00:00Z",
      "type" => "OPERATION_TYPE_OUTPUT",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "-15000", "nano" => 0 },
      "description" => "Withdrawal"
    },
    {
      "id" => "op-progress-1",
      "date" => "2025-06-06T10:00:00Z",
      "type" => "OPERATION_TYPE_BUY",
      "state" => "OPERATION_STATE_PROGRESS",
      "instrumentUid" => "uid-sber",
      "quantity" => "10",
      "payment" => { "currency" => "rub", "units" => "-2600", "nano" => 0 },
      "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX", "country_code" => "RU" }
    }
  ].freeze

  setup do
    @family = families(:dylan_family)
    @item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "test-token")
    @tinkoff_account = @item.tinkoff_invest_accounts.create!(
      name: "Main Brokerage",
      tinkoff_invest_account_id: "acct-broker-01",
      account_type: "ACCOUNT_TYPE_TINKOFF",
      currency: "RUB",
      current_balance: BigDecimal("1600000"),
      cash_balance: BigDecimal("116100"),
      raw_portfolio_payload: PORTFOLIO,
      raw_operations_payload: OPERATIONS
    )
    @account = @family.accounts.create!(name: "Main Brokerage", balance: 0, cash_balance: 0, currency: "RUB", accountable: Investment.new)
    @tinkoff_account.ensure_account_provider!(@account)

    Security.find_or_create_by!(ticker: "SBER", exchange_operating_mic: "MISX")
    Security.find_or_create_by!(ticker: "SU26238RMFS4", exchange_operating_mic: "MISX")
  end

  test "updates account balance, cash balance, and imports holdings including bond NKD while skipping currency" do
    result = TinkoffInvestAccount::Processor.new(@tinkoff_account).process

    @account.reload
    assert_equal BigDecimal("1600000"), @account.balance
    assert_equal BigDecimal("116100"), @account.cash_balance
    assert_equal 2, result[:holdings]

    holdings = @account.holdings.where(date: Date.current).includes(:security).index_by { |h| h.security.ticker }
    assert_equal [ "SBER", "SU26238RMFS4" ].sort, holdings.keys.sort

    sber = holdings["SBER"]
    assert_equal BigDecimal("5000"), sber.qty
    assert_equal BigDecimal("260"), sber.price
    assert_equal BigDecimal("240.5"), sber.cost_basis

    bond = holdings["SU26238RMFS4"]
    assert_equal BigDecimal("200"), bond.qty
    assert_equal BigDecimal("568.5"), bond.price
    assert_equal BigDecimal("113700"), bond.amount
    assert_equal BigDecimal("590"), bond.cost_basis
  end

  test "maps executed operations with Sure sign conventions and skips non-executed ones" do
    result = TinkoffInvestAccount::Processor.new(@tinkoff_account).process

    assert_equal 3, result[:trades]
    assert_equal 1, result[:dividends]
    assert_equal 7, result[:transactions]

    assert_nil @account.entries.find_by(external_id: "tinkoff_invest_op_op-progress-1")

    buy = entry("op-buy-1")
    assert_equal [ BigDecimal("6000"), BigDecimal("240.5"), BigDecimal("1443000"), "Buy" ],
                 [ buy.entryable.qty, buy.entryable.price, buy.amount, buy.entryable.investment_activity_label ]

    sell = entry("op-sell-1")
    assert_equal [ BigDecimal("-1000"), BigDecimal("280"), BigDecimal("-280000"), "Sell" ],
                 [ sell.entryable.qty, sell.entryable.price, sell.amount, sell.entryable.investment_activity_label ]

    repay_full = entry("op-repay-full-1")
    assert_equal [ BigDecimal("-10"), BigDecimal("1000"), BigDecimal("-10000"), "Sell" ],
                 [ repay_full.entryable.qty, repay_full.entryable.price, repay_full.amount, repay_full.entryable.investment_activity_label ]

    assert_equal [ BigDecimal("-1000000"), "Contribution", "investment_contribution" ],
                 [ entry("op-in-1").amount, entry("op-in-1").entryable.investment_activity_label, entry("op-in-1").entryable.kind ]

    assert_equal [ BigDecimal("15000"), "Withdrawal", "funds_movement" ],
                 [ entry("op-out-1").amount, entry("op-out-1").entryable.investment_activity_label, entry("op-out-1").entryable.kind ]

    assert_equal [ BigDecimal("721.5"), "Fee" ], [ entry("op-fee-1").amount, entry("op-fee-1").entryable.investment_activity_label ]
    assert_equal [ BigDecimal("-199800"), "Dividend" ], [ entry("op-div-1").amount, entry("op-div-1").entryable.investment_activity_label ]
    assert_equal [ BigDecimal("25974"), "Fee" ], [ entry("op-tax-1").amount, entry("op-tax-1").entryable.investment_activity_label ]
    assert_equal [ BigDecimal("-500"), "Other" ], [ entry("op-tax-refund-1").amount, entry("op-tax-refund-1").entryable.investment_activity_label ]
    assert_equal [ BigDecimal("-7080"), "Interest" ], [ entry("op-coupon-1").amount, entry("op-coupon-1").entryable.investment_activity_label ]
    assert_equal [ BigDecimal("-5000"), "Other" ], [ entry("op-amort-1").amount, entry("op-amort-1").entryable.investment_activity_label ]
  end

  test "re-processing is idempotent and creates no duplicate entries or holdings" do
    processor = TinkoffInvestAccount::Processor.new(@tinkoff_account)
    processor.process
    initial_entries = @account.entries.count
    initial_holdings = @account.holdings.count

    @tinkoff_account.update!(raw_operations_payload: OPERATIONS)
    processor.process

    assert_equal initial_entries, @account.entries.count
    assert_equal initial_holdings, @account.holdings.count
  end

  test "reconciles changing operation IDs across overlapping syncs without duplicating trades or legacy entries" do
    legacy_security = Security.find_by!(ticker: "SBER", exchange_operating_mic: "MISX")
    legacy_entry = Account::ProviderImportAdapter.new(@account).import_trade(
      external_id: "tinkoff_invest_op_legacy-buy-1",
      security: legacy_security,
      quantity: 5,
      price: 250,
      amount: 1250,
      currency: "RUB",
      date: Date.new(2025, 1, 10),
      source: "tinkoff_invest",
      activity_label: "Buy"
    )
    legacy_entry.entryable.update!(
      extra: {
        "tinkoff_invest" => {
          "operation_id" => "legacy-buy-1",
          "trade_numbers" => [ "TRD-9001" ]
        }
      }
    )

    @tinkoff_account.update!(
      raw_portfolio_payload: { "positions" => [] },
      raw_operations_payload: [
        {
          "id" => "reloaded-buy-999",
          "date" => "2025-01-10T10:00:00Z",
          "type" => "OPERATION_TYPE_BUY",
          "state" => "OPERATION_STATE_EXECUTED",
          "instrumentUid" => "uid-sber",
          "quantity" => "5",
          "price" => { "currency" => "rub", "units" => "250", "nano" => 0 },
          "payment" => { "currency" => "rub", "units" => "-1250", "nano" => 0 },
          "trades" => [ { "num" => "TRD-9001", "quantity" => "5" } ],
          "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX" }
        },
        {
          "id" => "op-div-v1",
          "date" => "2025-02-01T09:00:00.123456Z",
          "type" => "OPERATION_TYPE_DIVIDEND",
          "state" => "OPERATION_STATE_EXECUTED",
          "instrumentUid" => "uid-sber",
          "payment" => { "currency" => "rub", "units" => "1000", "nano" => 0 },
          "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX" }
        }
      ]
    )

    TinkoffInvestAccount::Processor.new(@tinkoff_account).process
    assert_equal 2, @account.entries.where(source: "tinkoff_invest").count
    assert_equal 1, @account.entries.where(entryable_type: "Trade").count
    assert_equal "reloaded-buy-999", legacy_entry.entryable.reload.extra.dig("tinkoff_invest", "operation_id")

    # Re-sync with both IDs changed again
    @tinkoff_account.update!(
      raw_operations_payload: [
        {
          "id" => "reloaded-buy-1000",
          "date" => "2025-01-10T10:00:00Z",
          "type" => "OPERATION_TYPE_BUY",
          "state" => "OPERATION_STATE_EXECUTED",
          "instrumentUid" => "uid-sber",
          "quantity" => "5",
          "price" => { "currency" => "rub", "units" => "250", "nano" => 0 },
          "payment" => { "currency" => "rub", "units" => "-1250", "nano" => 0 },
          "trades" => [ { "num" => "TRD-9001", "quantity" => "5" } ],
          "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX" }
        },
        {
          "id" => "op-div-v2",
          "date" => "2025-02-01T09:00:00.123456Z",
          "type" => "OPERATION_TYPE_DIVIDEND",
          "state" => "OPERATION_STATE_EXECUTED",
          "instrumentUid" => "uid-sber",
          "payment" => { "currency" => "rub", "units" => "1000", "nano" => 0 },
          "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX" }
        }
      ]
    )

    TinkoffInvestAccount::Processor.new(@tinkoff_account).process
    assert_equal 2, @account.entries.where(source: "tinkoff_invest").count
    assert_equal 1, @account.entries.where(entryable_type: "Trade").count
  end

  test "retains failed operations and keeps checkpoint unchanged until retry succeeds" do
    good_op = {
      "id" => "op-good-1",
      "date" => "2025-02-10T10:00:00Z",
      "type" => "OPERATION_TYPE_INPUT",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "5000", "nano" => 0 }
    }
    bad_op = {
      "id" => "op-bad-1",
      "date" => "2025-02-11T10:00:00Z",
      "type" => "OPERATION_TYPE_INPUT",
      "state" => "OPERATION_STATE_EXECUTED",
      "payment" => { "currency" => "rub", "units" => "1000", "nano" => 0 }
    }

    @tinkoff_account.update!(
      last_synced_at: Time.utc(2025, 2, 1, 0, 0, 0),
      raw_portfolio_payload: { "positions" => [] },
      raw_operations_payload: [ good_op, bad_op ]
    )

    adapter = Account::ProviderImportAdapter.new(@account)
    Account::ProviderImportAdapter.stubs(:new).returns(adapter)
    original_import = adapter.method(:import_transaction)
    adapter.define_singleton_method(:import_transaction) do |**kwargs|
      raise "transient DB write failure" if kwargs[:notes]&.include?("op-bad-1")

      original_import.call(**kwargs)
    end

    assert_raises(TinkoffInvestAccount::Processor::PartialProcessingError) do
      TinkoffInvestAccount::Processor.new(@tinkoff_account).process
    end

    @tinkoff_account.reload
    assert_equal Time.utc(2025, 2, 1, 0, 0, 0), @tinkoff_account.last_synced_at
    assert_equal [ "op-bad-1" ], @tinkoff_account.raw_operations_payload.map { |op| op["id"] }
    assert_equal 1, @account.entries.where(source: "tinkoff_invest").count
  end

  test "reconciles sold holdings across same-day and empty snapshots without dropping on nil payload" do
    @tinkoff_account.update!(raw_operations_payload: [])
    TinkoffInvestAccount::Processor.new(@tinkoff_account).process
    assert_equal [ "SBER", "SU26238RMFS4" ].sort, @account.current_holdings.map(&:ticker).sort

    # Missing positions key preserves existing holdings
    @tinkoff_account.update!(raw_portfolio_payload: {})
    TinkoffInvestAccount::Processor.new(@tinkoff_account.reload).process
    assert_equal [ "SBER", "SU26238RMFS4" ].sort, @account.current_holdings.map(&:ticker).sort

    # Same-day snapshot omits bond position -> zeroed
    @tinkoff_account.update!(raw_portfolio_payload: { "positions" => [ PORTFOLIO["positions"].first ] })
    TinkoffInvestAccount::Processor.new(@tinkoff_account.reload).process
    assert_equal [ "SBER" ], @account.current_holdings.map(&:ticker)

    # Empty snapshot -> all positions zeroed
    @tinkoff_account.update!(raw_portfolio_payload: { "positions" => [] })
    TinkoffInvestAccount::Processor.new(@tinkoff_account.reload).process
    assert_empty @account.current_holdings
  end

  test "skips negative short positions safely with a DebugLogEntry warning" do
    @tinkoff_account.update!(
      raw_operations_payload: [],
      raw_portfolio_payload: {
        "positions" => [
          {
            "figi" => "BBG004730N88",
            "instrumentUid" => "uid-sber",
            "instrumentType" => "share",
            "quantity" => { "units" => "-10", "nano" => 0 },
            "currentPrice" => { "currency" => "rub", "units" => "260", "nano" => 0 },
            "resolved_instrument" => { "ticker" => "SBER", "name" => "Sberbank", "exchange_operating_mic" => "MISX" }
          }
        ]
      }
    )

    assert_difference -> { DebugLogEntry.where(source: "tinkoff_invest", level: "warn").count }, 1 do
      result = TinkoffInvestAccount::Processor.new(@tinkoff_account).process
      assert_equal 0, result[:holdings]
    end
    assert_empty @account.holdings
  end

  private

    def entry(op_id)
      Entry.joins("LEFT JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
        .joins("LEFT JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: @account.id, source: "tinkoff_invest")
        .where(
          "trades.extra -> 'tinkoff_invest' ->> 'operation_id' = ? OR transactions.extra -> 'tinkoff_invest' ->> 'operation_id' = ?",
          op_id, op_id
        ).first!
    end
end
