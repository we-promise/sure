require "test_helper"

class MoomooAccount::CurrencySplitTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @moomoo_account = moomoo_accounts(:main_account)
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: Date.current, rate: 1.3)
  end

  test "each currency gets its buying power, scaled to the cash and fund assets, plus its positions" do
    # 1,287 SGD and 990 USD at 1.3 are 2,574 SGD, 99% of the 2,600 SGD of cash and funds.
    split = split_for(funds(sg: "1287", us: "990"), positions)

    assert_equal %w[SGD USD], split.currencies
    assert split.multiple_currencies?
    assert_equal(
      { "SGD" => { balance: BigDecimal("3225"), cash: BigDecimal("1300") }, "USD" => { balance: BigDecimal("2800"), cash: BigDecimal("1000") } },
      split.balances
    )
  end

  test "a position without a market value counts at its price" do
    unvalued = positions.map { |position| position["code"] == "US.AAPL" ? position.except("market_val").merge("nominal_price" => "180.000") : position }

    assert_equal BigDecimal("2800"), split_for(funds(sg: "1287", us: "990"), unvalued).balances["USD"][:balance]
  end

  test "the currencies add up to moomoo's total" do
    balances = split_for(funds(sg: "1287", us: "990"), positions).balances

    total = balances["SGD"][:balance] + balances["USD"][:balance] * BigDecimal("1.3")
    assert_equal BigDecimal("6865"), total
  end

  test "an account with only its home currency is not split" do
    split = split_for(funds(sg: "2600", us: "0"), [ positions.first ])

    assert_equal [ "SGD" ], split.currencies
    assert_not split.multiple_currencies?
  end

  test "an account that holds only a foreign currency is not split" do
    split = split_for(funds(sg: "0", us: "990"), [ positions.last ])

    assert_equal [ "SGD" ], split.currencies
    assert_not split.multiple_currencies?
  end

  test "an account already split keeps its home currency when that currency runs out" do
    @moomoo_account.currency_accounts.create!(
      moomoo_item: @moomoo_account.moomoo_item, moomoo_account_id: @moomoo_account.moomoo_account_id, currency: "USD",
      name: "moomoo SG ••3456 (USD)", account_kind: "securities"
    )

    assert_equal %w[SGD USD], split_for(funds(sg: "0", us: "990"), [ positions.last ]).currencies
  end

  test "a currency held before counts, from the stored trades and cash log" do
    @moomoo_account.update!(raw_cash_logs_payload: [ { "transaction_name" => "Cash Dividend", "cash_change" => "+1.00", "balance" => "Balance: 1.00 HKD" } ])

    assert_equal %w[SGD HKD], split_for(funds(sg: "2600", us: "0"), []).currencies
  end

  test "buying power too far from the cash and fund assets is not divided" do
    # 1,287 SGD and 500 USD at 1.3 are 1,937 SGD, 74.5% of 2,600.
    error = assert_raises(MoomooAccount::CurrencySplit::Mismatch) { split_for(funds(sg: "1287", us: "500"), positions).balances }

    assert_match "74.5%", error.message
  end

  test "funds without cash per currency are not divided" do
    assert_raises(MoomooAccount::CurrencySplit::Mismatch) do
      split_for({ "currency" => "SGD", "total_assets" => "6865", "cash" => "0", "funds_assets" => "2600" }, positions).balances
    end
  end

  test "buying power Sure can't convert is not divided" do
    ExchangeRate.delete_all
    ExchangeRate.stubs(:provider).returns(nil)

    error = assert_raises(MoomooAccount::CurrencySplit::Mismatch) { split_for(funds(sg: "1287", us: "990"), positions).balances }
    assert_match "exchange rate", error.message
  end

  test "an account with no cash at all keeps only its positions" do
    balances = split_for(funds(sg: "0", us: "0", funds_assets: "0"), positions).balances

    assert_equal({ balance: BigDecimal("1925"), cash: BigDecimal("0") }, balances["SGD"])
    assert_equal({ balance: BigDecimal("1800"), cash: BigDecimal("0") }, balances["USD"])
  end

  private

    def split_for(funds, positions)
      MoomooAccount::CurrencySplit.new(@moomoo_account, funds: funds, positions: positions)
    end

    def funds(sg:, us:, funds_assets: "2600")
      {
        "currency" => "SGD", "total_assets" => "6865", "cash" => "0", "funds_assets" => funds_assets, "securities_assets" => "4265",
        "sg_net_cash_power" => sg, "us_net_cash_power" => us, "hk_net_cash_power" => "0"
      }
    end

    def positions
      [
        { "position_side" => "LONG", "code" => "SG.D05", "security_type" => "STOCK", "qty" => "50", "currency" => "SGD", "market_val" => "1925.00" },
        { "position_side" => "LONG", "code" => "US.AAPL", "security_type" => "STOCK", "qty" => "10", "currency" => "USD", "market_val" => "1800.00" }
      ]
    end
end
