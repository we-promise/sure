require "test_helper"

class EtoroAccountTotalsProcessorTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 10, 24)

    @etoro_account = etoro_accounts(:main_account)
    @etoro_account.etoro_item.update!(raw_instruments_payload: { "1001" => { "symbol" => "AAPL", "name" => "Apple", "type_id" => 5 } })
    @etoro_account.update!(
      current_balance: 1500,
      cash_balance: 900,
      raw_positions_payload: [ position(11, 1001, units: 2, amount: 300, pnl: 50, opened: "2026-03-01T09:00:00Z") ],
      raw_trades_payload: [ closed_trade(21, 1001, units: 4, investment: 400, net_profit: 40, opened: "2026-01-10T10:00:00Z", closed: "2026-02-10T15:00:00Z") ],
      # No figures for 22 October. eToro's figures for today give way to the
      # current ones.
      raw_balance_history_payload: [
        { "date" => "2026-10-20", "total" => "1400", "cash" => "1000", "currency" => "USD" },
        { "date" => "2026-10-21", "total" => "1420", "cash" => "980", "currency" => "USD" },
        { "date" => "2026-10-23", "total" => "1450", "cash" => "950", "currency" => "USD" },
        { "date" => "2026-10-24", "total" => "1480", "cash" => "1000", "currency" => "USD" }
      ]
    )

    @account = Account.create_from_etoro_account(@etoro_account)
    @etoro_account.ensure_account_provider!(@account)

    Security::Resolver.stubs(:new).with("AAPL").returns(stub(resolve: securities(:aapl)))
  end

  test "the account follows eToro's total and cash each day, the rest as one holding" do
    @etoro_account.update!(display_mode: :totals)

    assert_equal({ holdings: 1, failed_records: 0 }, process)
    materialize

    expected = {
      Date.new(2026, 10, 20) => [ 1400, 1000 ],
      Date.new(2026, 10, 21) => [ 1420, 980 ],
      Date.new(2026, 10, 23) => [ 1450, 950 ],
      Date.new(2026, 10, 24) => [ 1500, 900 ]
    }
    assert_equal expected.transform_values { |figures| figures.map { |figure| BigDecimal(figure) } }, balances_on(expected.keys)

    security = EtoroAccount::TotalsProcessor.security_for(@account)
    assert_equal [ security.id ], @account.holdings.distinct.pluck(:security_id)
    assert_equal BigDecimal("440"), @account.holdings.find_by!(date: Date.new(2026, 10, 21), account_provider_id: @etoro_account.account_provider.id).amount
    today = @account.holdings.find_by!(date: Date.current)
    assert_equal [ BigDecimal("1"), BigDecimal("600") ], [ today.qty, today.amount ]
    assert_equal I18n.t("etoro_items.totals.security_name"), today.name
    assert_empty @account.trades

    @account.reload
    assert_equal [ BigDecimal("1500"), BigDecimal("900") ], [ @account.balance, @account.cash_balance ]
  end

  test "a day eToro sent no figures for keeps the investments of the day before and the cash of the day after" do
    @etoro_account.update!(display_mode: :totals)

    process
    materialize

    gap = Date.new(2026, 10, 22)
    assert_equal BigDecimal("440"), @account.holdings.where(date: gap).sum(:amount)
    assert_equal({ gap => [ BigDecimal("1390"), BigDecimal("950") ] }, balances_on([ gap ]))
  end

  test "a day eToro sent a total but no cash for keeps the total and the investments of the day before" do
    history = @etoro_account.raw_balance_history_payload + [ { "date" => "2026-10-22", "total" => "1430", "currency" => "USD" } ]
    @etoro_account.update!(display_mode: :totals, raw_balance_history_payload: history)

    process
    materialize

    day = Date.new(2026, 10, 22)
    assert_equal BigDecimal("440"), @account.holdings.where(date: day).sum(:amount)
    assert_equal({ day => [ BigDecimal("1430"), BigDecimal("990") ] }, balances_on([ day ]))
  end

  test "a day whose cash exceeds its total holds no investments, and the total as cash" do
    @etoro_account.update!(display_mode: :totals, raw_balance_history_payload: @etoro_account.raw_balance_history_payload.map do |day|
      day["date"] == "2026-10-21" ? day.merge("cash" => "1500") : day
    end)

    process
    materialize

    day = Date.new(2026, 10, 21)
    security = EtoroAccount::TotalsProcessor.security_for(@account)
    assert_equal BigDecimal("0"), @account.holdings.find_by!(security: security, date: day).amount
    assert_equal({ day => [ BigDecimal("1420"), BigDecimal("1420") ] }, balances_on([ day ]))
  end

  test "the investments are valued as invested, with no price provider asked" do
    @etoro_account.update!(display_mode: :totals)

    process
    materialize

    security = EtoroAccount::TotalsProcessor.security_for(@account)
    assert security.offline?
    assert_not Security.standard.exists?(security.id), "health checks, which ask a price provider, take only standard securities"
    assert_not Security.online.exists?(security.id), "the market data import prices only online securities"
    assert_not EtoroAccount::PriceHistoryProcessor.priceable?(security)
    assert_equal BigDecimal("600"), @account.balances.find_by!(date: Date.current).end_non_cash_balance
  end

  test "switching to totals removes eToro's trades and holdings and starts the history at eToro's daily balances" do
    process
    materialize
    assert @account.trades.any?
    assert @account.holdings.where(security: securities(:aapl)).any?
    assert_operator Account.find(@account.id).opening_anchor_date, :<, Date.new(2026, 1, 10)

    @etoro_account.update!(display_mode: :totals)
    process
    materialize

    assert_empty @account.trades
    assert_empty @account.holdings.where.not(security: EtoroAccount::TotalsProcessor.security_for(@account))
    assert_equal Date.new(2026, 10, 19), Account.find(@account.id).opening_anchor_date
  end

  test "switching to totals lets go of the securities only eToro's trades used" do
    @etoro_account.etoro_item.update!(own_securities: true)
    process
    own = Security.find_by!(ticker: "ETORO:AAPL")
    assert @account.trades.any?

    @etoro_account.update!(display_mode: :totals)
    process

    assert_not Security.exists?(own.id)
    assert Security.exists?(securities(:aapl).id)
  end

  test "moving the opening anchor queues no sync of the account" do
    process
    @etoro_account.update!(display_mode: :totals)

    process

    assert_equal Date.new(2026, 10, 19), Account.find(@account.id).opening_anchor_date
    assert_empty @account.syncs.where(parent_id: nil)
  end

  test "only today's investments count as the account's current holdings" do
    @etoro_account.update!(display_mode: :totals)

    process

    assert_equal [ Date.current ], current_holdings.pluck(:date)
    assert_equal Account.find(@account.id).current_holdings.pluck(:id), current_holdings.pluck(:id)
  end

  test "the day after the switch only that day's investments count as current" do
    @etoro_account.update!(display_mode: :totals)
    process
    # Each row of the switch day is taken as written at the time of that
    # sync, whichever clock stamped it, as the database's does not follow
    # travel_to.
    @account.holdings.update_all(created_at: Time.current, updated_at: Time.current)

    travel_to Date.new(2026, 10, 25)
    process

    assert_equal [ Date.current ], current_holdings.pluck(:date)
    assert_equal Account.find(@account.id).current_holdings.pluck(:id), current_holdings.pluck(:id)
  end

  test "a trade added by hand stays in totals mode" do
    manual = @account.entries.create!(
      date: Date.new(2026, 10, 1), name: "Buy", amount: 100, currency: "USD",
      entryable: Trade.new(security: securities(:msft), qty: 1, price: 100, currency: "USD")
    )
    @etoro_account.update!(display_mode: :totals)

    process

    assert Entry.exists?(manual.id)
  end

  test "a trade added by hand counts as a holding beside the investments, so the cash before it is not eToro's" do
    (Date.new(2026, 10, 19)..Date.current).each do |date|
      Security::Price.create!(security: securities(:msft), date: date, price: 100, currency: "USD")
    end
    @account.entries.create!(
      date: Date.new(2026, 10, 22), name: "Sell", amount: -150, currency: "USD",
      entryable: Trade.new(security: securities(:msft), qty: -1, price: 150, currency: "USD")
    )
    @etoro_account.update!(display_mode: :totals)

    process
    materialize

    # The days before the sell hold the share it sold, worth 100, which the
    # cash leaves out; the totals stay eToro's.
    assert_equal BigDecimal("1"), @account.holdings.find_by!(security: securities(:msft), date: Date.new(2026, 10, 21)).qty
    expected = {
      Date.new(2026, 10, 20) => [ 1400, 900 ],
      Date.new(2026, 10, 21) => [ 1420, 880 ],
      Date.new(2026, 10, 23) => [ 1450, 950 ]
    }
    assert_equal expected.transform_values { |figures| figures.map { |figure| BigDecimal(figure) } }, balances_on(expected.keys)
  end

  test "switching back to holdings rebuilds the trades and holdings from the stored payloads" do
    @etoro_account.update!(display_mode: :totals)
    process
    materialize
    security = EtoroAccount::TotalsProcessor.security_for(@account)

    @etoro_account.update!(display_mode: :holdings)
    process
    materialize

    assert_empty @account.holdings.where(security: security)
    assert_equal BigDecimal("2"), @account.holdings.find_by!(security: securities(:aapl), date: Date.current).qty
    assert_equal %w[etoro_position_11_open etoro_position_21_close_1770735600 etoro_position_21_open].sort,
      @account.entries.where(source: "etoro", entryable_type: "Trade").pluck(:external_id).sort
    assert_operator Account.find(@account.id).opening_anchor_date, :<, Date.new(2026, 1, 10)
    assert_equal BigDecimal("1500"), @account.balances.find_by!(date: Date.current).balance
  end

  test "an account shown as totals keeps its prices out of the connection's priced securities" do
    other = EtoroItem.create!(family: @etoro_account.etoro_item.family, name: "Other", api_key: "other_key", user_key: "other_user",
      raw_instruments_payload: { "1001" => { "price_history" => { "security_id" => securities(:aapl).id } } })
    other_account = other.etoro_accounts.create!(etoro_account_id: "other", currency: "USD")
    other_account.ensure_account_provider!(accounts(:investment))

    assert_includes @etoro_account.etoro_item.securities_priced_elsewhere, securities(:aapl).id

    other_account.update!(display_mode: :totals)
    assert_not_includes @etoro_account.etoro_item.reload.securities_priced_elsewhere, securities(:aapl).id
  end

  test "rejects a display mode it does not know" do
    @etoro_account.display_mode = "per_copy"

    assert_not @etoro_account.valid?
  end

  private

    def process
      EtoroAccount::Processor.new(@etoro_account.reload).process
    end

    def materialize
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    def balances_on(dates)
      @account.balances.where(date: dates).order(:date).to_h { |balance| [ balance.date, [ balance.balance, balance.cash_balance ] ] }
    end

    # What the dashboard and reports count as held (InvestmentStatement).
    def current_holdings
      Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    end

    def position(id, instrument_id, units:, amount:, pnl:, opened:)
      {
        "positionID" => id, "instrumentID" => instrument_id, "mirrorID" => 0, "isBuy" => true, "leverage" => 1,
        "units" => units, "amount" => amount, "unitsBaseValueDollars" => amount, "openDateTime" => opened,
        "settlementTypeID" => 1, "unrealizedPnL" => { "pnL" => pnl }
      }
    end

    def closed_trade(id, instrument_id, units:, investment:, net_profit:, opened:, closed:)
      {
        "positionId" => id, "instrumentId" => instrument_id, "isBuy" => true, "leverage" => 1, "units" => units,
        "investment" => investment, "netProfit" => net_profit, "openTimestamp" => opened, "closeTimestamp" => closed
      }
    end
end
