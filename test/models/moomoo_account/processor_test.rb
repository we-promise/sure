require "test_helper"

class MoomooAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @family = families(:dylan_family)
    @moomoo_account = moomoo_accounts(:main_account)
    @moomoo_account.update!(current_balance: 12_000, cash_balance: 500, raw_positions_payload: positions)
    @account = @family.accounts.create!(name: "moomoo SG", balance: 0, cash_balance: 0, currency: "SGD", accountable: Investment.new)
    @moomoo_account.ensure_account_provider!(@account)
    @moomoo_account.reload

    Security::Resolver.stubs(:new).returns(stub(resolve: nil))
    Security::Resolver.stubs(:new).with("AAPL", exchange_operating_mic: nil, country_code: "US").returns(stub(resolve: securities(:aapl)))

    ExchangeRate.create!(from_currency: "HKD", to_currency: "SGD", date: Date.current, rate: 0.17)
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: Date.current, rate: 1.3)
  end

  test "imports each long stock as a holding in the currency it trades in" do
    process

    hk = holding_for("HK.00700")
    assert_equal "0700", hk.security.ticker
    assert_equal "XHKG", hk.security.exchange_operating_mic
    assert_equal "HKD", hk.currency
    assert_equal BigDecimal("100"), hk.qty
    assert_equal BigDecimal("40000"), hk.amount
    assert_equal BigDecimal("400"), hk.price
    assert_equal BigDecimal("350"), hk.cost_basis

    sg = holding_for("SG.D05")
    assert_equal [ "D05", "XSES", "SGD" ], [ sg.security.ticker, sg.security.exchange_operating_mic, sg.currency ]
    assert_nil sg.cost_basis

    us = holding_for("US.AAPL")
    assert_equal securities(:aapl), us.security
    assert_equal "USD", us.currency

    assert_equal 3, @account.holdings.count
  end

  test "skipped positions stay in cash, which keeps moomoo's total" do
    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "info").where("message LIKE ?", "%skipped 2 positions%").count }, 1 do
      process
    end

    @account.reload
    assert_equal "SGD", @account.currency
    assert_equal BigDecimal("12000"), @account.balance
    # 40,000 HKD at 0.17, 1,925 SGD and 1,800 USD at 1.3 are 11,065 SGD of holdings.
    assert_equal BigDecimal("935"), @account.cash_balance
  end

  test "a stale snapshot is left as it is until a new one comes" do
    # The last sync listed the account but couldn't use its funds, so it keeps
    # the positions of the one before; the sale since waits for a new snapshot.
    @moomoo_account.update!(
      last_seen_at: Time.current, last_positions_sync: 2.days.ago, current_balance: 2025,
      raw_positions_payload: [ positions[1] ],
      raw_fills_payload: [ fill("s1", side: "SELL", code: "SG.D05", qty: "50", price: "38.5", at: 1.day.ago) ]
    )

    process

    assert_nil @account.entries.find_by(external_id: "moomoo_fill_1234567890123456_s1")
    assert_empty @account.holdings
  end

  test "without an exchange rate the cash moomoo reports is used" do
    ExchangeRate.where(to_currency: "SGD").delete_all
    ExchangeRate.stubs(:provider).returns(nil)

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "warn").where("message LIKE ?", "%FX conversion failed%").count }, 1 do
      process
    end

    assert_equal BigDecimal("500"), @account.reload.cash_balance
  end

  test "a buy becomes a trade in the order's currency on its market's date" do
    # 02:00 UTC is still the previous day in New York.
    @moomoo_account.update!(
      raw_fills_payload: [ fill("d1", side: "BUY", code: "US.AAPL", qty: "10", price: "180", at: Time.utc(2026, 10, 20, 2, 0)) ],
      raw_orders_payload: { "o-d1" => { "order_id" => "o-d1", "currency" => "USD", "security_type" => "STOCK" } }
    )

    process

    entry = trade_entry("d1")
    assert_equal Date.new(2026, 10, 19), entry.date
    assert_equal BigDecimal("1800"), entry.amount
    assert_equal "USD", entry.currency
    assert_equal BigDecimal("10"), entry.trade.qty
    assert_equal BigDecimal("180"), entry.trade.price
    assert_equal "Buy", entry.trade.investment_activity_label
    assert_equal securities(:aapl), entry.trade.security
  end

  test "a sell is a negative quantity and money coming in" do
    @moomoo_account.update!(raw_fills_payload: [ fill("d2", side: "SELL", code: "US.AAPL", qty: "10", price: "180") ])

    process

    entry = trade_entry("d2")
    assert_equal BigDecimal("-10"), entry.trade.qty
    assert_equal BigDecimal("-1800"), entry.amount
    assert_equal "Sell", entry.trade.investment_activity_label
  end

  test "a fill moomoo cancelled removes its trade unless the user changed it" do
    @moomoo_account.update!(raw_fills_payload: [ fill("d3", side: "BUY", code: "US.AAPL"), fill("d4", side: "BUY", code: "US.AAPL") ])
    process
    trade_entry("d4").update!(user_modified: true)

    @moomoo_account.update!(raw_fills_payload: [ fill("d3", side: "BUY", code: "US.AAPL", status: "CANCELLED"), fill("d4", side: "BUY", code: "US.AAPL", status: "CANCELLED") ])
    process

    assert_nil @account.entries.find_by(external_id: "moomoo_fill_1234567890123456_d3")
    assert trade_entry("d4").present?
  end

  test "short sales, buy-backs and options are skipped" do
    @moomoo_account.update!(raw_fills_payload: [
      fill("s1", side: "SELL_SHORT", code: "US.AAPL"),
      fill("s2", side: "BUY_BACK", code: "US.AAPL"),
      fill("s3", side: "BUY", code: "US.AAPL240119C190000")
    ])

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "info").where("message LIKE ?", "%skipped 3 fills%").count }, 1 do
      process
    end

    assert_equal 0, @account.entries.where(source: "moomoo", entryable_type: "Trade").count
  end

  test "a fill without a known order takes its market's currency and timezone" do
    @moomoo_account.update!(raw_fills_payload: [ fill("c1", side: "BUY", code: "SH.600519", qty: "100", price: "1500", at: Time.utc(2026, 10, 21, 17, 0)) ])

    process

    entry = trade_entry("c1")
    assert_equal "CNH", entry.currency
    assert_equal Date.new(2026, 10, 22), entry.date
    assert_equal [ "600519", "XSHG" ], [ entry.trade.security.ticker, entry.trade.security.exchange_operating_mic ]
  end

  test "processing again changes nothing" do
    @moomoo_account.update!(raw_fills_payload: [ fill("d5", side: "BUY", code: "US.AAPL") ])
    process

    assert_no_difference [ -> { @account.entries.count }, -> { @account.holdings.count } ] do
      MoomooAccount::Processor.new(@moomoo_account.reload).process
    end
  end

  test "a futures account is not processed" do
    @moomoo_account.update!(account_kind: "futures")

    process

    assert_equal 0, @account.holdings.count
    assert_equal BigDecimal("0"), @account.reload.balance
  end

  # 100 bought at 10 and 75 sold at 12 leave moomoo's diluted cost at 4. The
  # market value less the unrealized P&L leaves the average cost of 10.
  test "the cost basis is moomoo's average cost, not its diluted cost" do
    @moomoo_account.update!(raw_positions_payload: [
      sgd_position("SG.D05", qty: 25, price: 12, cost_price: "4.000", unrealized_pl: "50.00"),
      sgd_position("SG.C6L", qty: 100, price: 6, cost_price: "4.000")
    ])

    process

    assert_equal BigDecimal("10"), holding_for("SG.D05").cost_basis
    assert_nil holding_for("SG.C6L").cost_basis
  end

  test "selling the last position closes its holding" do
    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025)
    assert_no_difference -> { @account.holdings.count } do
      sync_on("2026-10-23 18:00", positions: [ dbs(50) ], total: 2025)
    end

    sync_on("2026-10-24", positions: [], total: 2025)

    closed = holding_for("SG.D05")
    assert_equal BigDecimal("0"), closed.qty
    assert closed.account_provider_id.present?
    assert_empty @account.reload.current_holdings
    assert_equal BigDecimal("2025"), @account.cash_balance
  end

  test "a position sold since an earlier sync that day is closed, and a rebuy reopens it" do
    sync_on("2026-10-24 02:00", positions: [ dbs(50), sia(100) ], total: 2525)
    sync_on("2026-10-24 10:00", positions: [ dbs(0), sia(100) ], total: 2525)

    assert_equal [ BigDecimal("0") ], dbs_holdings_on(Date.current).map(&:qty)
    assert_equal [ "C6L" ], @account.reload.current_holdings.map(&:ticker)

    sync_on("2026-10-24 11:00", positions: [ dbs(20), sia(100) ], total: 2525)

    assert_equal [ BigDecimal("20") ], dbs_holdings_on(Date.current).map(&:qty)
  end

  test "a position without a market value is valued at its price, and one without either is not stored as worthless" do
    priced = sgd_position("SG.D05", qty: 50, price: 38.5, cost_price_valid: false).except("market_val")
    unpriced = sgd_position("SG.C6L", qty: 20, price: 5, cost_price_valid: false).except("market_val", "nominal_price")

    assert_difference -> { DebugLogEntry.where(source: "moomoo", level: "error").where("message LIKE ?", "%SG.C6L: moomoo reported no market value or price%").count }, 1 do
      sync_on("2026-10-24", positions: [ priced, unpriced ], total: 2025)
    end

    assert_equal [ [ "D05", BigDecimal("1925") ] ], @account.reload.holdings.map { |holding| [ holding.ticker, holding.amount ] }
  end

  test "a held position whose import fails stays open" do
    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025)
    Account::ProviderImportAdapter.any_instance.stubs(:import_holding).raises(StandardError, "boom")
    Account::ProviderImportAdapter.any_instance.expects(:import_holding).with { |**args| args[:quantity].zero? }.never

    sync_on("2026-10-24", positions: [ dbs(50) ], total: 2025)

    Account::ProviderImportAdapter.any_instance.unstub(:import_holding)
    assert_equal Date.new(2026, 10, 23), @account.reload.latest_provider_holdings_snapshot_date
    assert_equal [ [ "D05", BigDecimal("50") ] ], @account.current_holdings.map { |holding| [ holding.ticker, holding.qty ] }
  end

  test "a remapped holding stays on the user's security while held and closes there once sold" do
    chosen = Security.create!(ticker: "DBSDF", name: "DBS ADR", offline: true)
    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025)
    holding_for("SG.D05").remap_security!(chosen)

    sync_on("2026-10-23 18:00", positions: [ dbs(50) ], total: 2025)
    held = holding_for("SG.D05")
    assert_equal [ chosen, BigDecimal("50") ], [ held.security, held.qty ]

    sync_on("2026-10-24", positions: [], total: 2025)
    closed = holding_for("SG.D05")
    assert_equal [ chosen, dbs_security, BigDecimal("0"), true ], [ closed.security, closed.provider_security, closed.qty, closed.security_locked ]
  end

  test "the history before a sale is not counted twice" do
    buy = fill("b1", side: "BUY", code: "SG.D05", qty: "50", price: "30", at: Time.utc(2026, 10, 1, 2, 0))
    sell = fill("s1", side: "SELL", code: "SG.D05", qty: "50", price: "38.5", at: Time.utc(2026, 10, 24, 6, 0))

    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025, fills: [ buy ])
    materialize_balances
    sync_on("2026-10-24", positions: [], total: 2025, fills: [ buy, sell ])
    materialize_balances

    assert_equal BigDecimal("50"), dbs_holdings_on(Date.new(2026, 10, 22)).sum(&:qty)
    assert_equal BigDecimal("0"), dbs_holdings_on(Date.new(2026, 10, 24)).sum(&:qty)
    assert_equal BigDecimal("1600"), @account.balances.find_by!(date: Date.new(2026, 10, 22)).balance
    assert_equal BigDecimal("2025"), @account.balances.find_by!(date: Date.new(2026, 10, 24)).cash_balance
  end

  test "figures from an earlier snapshot keep that day's date" do
    snapshot_date = 3.days.ago.to_date
    ExchangeRate.create!(from_currency: "HKD", to_currency: "SGD", date: snapshot_date, rate: 0.17)
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: snapshot_date, rate: 1.3)
    @moomoo_account.update!(last_positions_sync: 3.days.ago)

    process

    assert_equal [ snapshot_date ], @account.holdings.distinct.pluck(:date)
    assert_equal snapshot_date, @account.valuations.current_anchor.first.entry.date
    assert_empty @account.entries.valuations.where(date: Date.current)
    assert_equal BigDecimal("935"), @account.reload.cash_balance
  end

  test "an account the last sync listed but couldn't refresh is left as it is" do
    sell = fill("s1", side: "SELL", code: "SG.D05", qty: "50", price: "38.5", at: Time.utc(2026, 10, 24, 6, 0))
    @moomoo_account.update!(last_seen_at: Time.current, last_positions_sync: 2.days.ago, raw_fills_payload: [ sell ])

    assert_no_difference -> { @account.entries.count + @account.holdings.count } do
      process
    end
    assert_equal BigDecimal("0"), @account.reload.balance
  end

  test "a code keeps the security it was imported as when a later search fails" do
    online = Security.create!(ticker: "D05.SI", name: "DBS", exchange_operating_mic: "XSES", country_code: "SG")
    Security::Resolver.stubs(:new).with("D05", exchange_operating_mic: "XSES", country_code: "SG").returns(stub(resolve: online))
    buy = fill("b1", side: "BUY", code: "SG.D05", qty: "50", price: "30", at: Time.utc(2026, 10, 1, 2, 0))
    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025, fills: [ buy ])

    Security::Resolver.expects(:new).with("D05", exchange_operating_mic: "XSES", country_code: "SG").never
    sync_on("2026-10-24", positions: [ dbs(50) ], total: 2025, fills: [ buy ])

    assert_equal online, holding_for("SG.D05").security
    assert_equal online, trade_entry("b1").trade.security
    assert_nil Security.find_by(ticker: "D05", exchange_operating_mic: "XSES")
  end

  test "a code sold before the last sync keeps the security its trades are on" do
    online = Security.create!(ticker: "D05.SI", name: "DBS", exchange_operating_mic: "XSES", country_code: "SG")
    Security::Resolver.stubs(:new).with("D05", exchange_operating_mic: "XSES", country_code: "SG").returns(stub(resolve: online))
    fills = [
      fill("b1", side: "BUY", code: "SG.D05", qty: "50", price: "30", at: Time.utc(2026, 9, 1, 2, 0)),
      fill("s1", side: "SELL", code: "SG.D05", qty: "50", price: "35", at: Time.utc(2026, 10, 1, 2, 0))
    ]
    sync_on("2026-10-23", positions: [], total: 1750, fills: fills)

    Security::Resolver.stubs(:new).with("D05", exchange_operating_mic: "XSES", country_code: "SG").returns(stub(resolve: nil))
    sync_on("2026-10-24", positions: [], total: 1750, fills: fills)

    assert_equal [ online ], %w[b1 s1].map { |deal_id| trade_entry(deal_id).trade.security }.uniq
  end

  test "trades of a remapped holding stay on the user's security" do
    chosen = Security.create!(ticker: "DBSDF", name: "DBS ADR", offline: true)
    buy = fill("b1", side: "BUY", code: "SG.D05", qty: "50", price: "30", at: Time.utc(2026, 10, 1, 2, 0))
    sync_on("2026-10-23", positions: [ dbs(50) ], total: 2025, fills: [ buy ])
    holding_for("SG.D05").remap_security!(chosen)

    sync_on("2026-10-24", positions: [ dbs(50) ], total: 2025, fills: [ buy ])

    assert_equal chosen, trade_entry("b1").trade.security
    today = holding_for("SG.D05")
    assert_equal [ chosen, dbs_security, true ], [ today.security, today.provider_security, today.security_locked ]
  end

  private

    def process
      MoomooAccount::Processor.new(@moomoo_account).process
    end

    # Stores the snapshot an import would have fetched at `time`, then
    # processes it, as a sync does.
    def sync_on(time, positions:, total:, fills: [])
      travel_to Time.zone.parse(time.include?(":") ? time : "#{time} 12:00")
      @moomoo_account.update!(
        current_balance: total, cash_balance: 0, raw_positions_payload: positions, last_positions_sync: Time.current,
        raw_fills_payload: fills, raw_orders_payload: fills.to_h { |fill| [ fill["order_id"], { "order_id" => fill["order_id"], "currency" => "SGD", "security_type" => "STOCK" } ] }
      )
      MoomooAccount::Processor.new(MoomooAccount.find(@moomoo_account.id)).process
    end

    # A fresh Account, as the account sync loads: it memoizes its anchor managers.
    def materialize_balances
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    def holding_for(code)
      @account.holdings.find_by!(external_id: "moomoo_holding_1234567890123456_#{code}_#{Date.current}")
    end

    def dbs_security
      Security.find_by!(ticker: "D05", exchange_operating_mic: "XSES")
    end

    def dbs_holdings_on(date)
      @account.holdings.where(security: dbs_security, date: date).to_a
    end

    def dbs(qty)
      sgd_position("SG.D05", qty: qty, price: 38.5, cost_price_valid: false)
    end

    def sia(qty)
      sgd_position("SG.C6L", qty: qty, price: 5, cost_price_valid: false)
    end

    def sgd_position(code, qty:, price:, cost_price: "30.000", cost_price_valid: true, unrealized_pl: nil)
      {
        "position_side" => "LONG", "code" => code, "stock_name" => code, "security_type" => "STOCK", "qty" => qty.to_s, "currency" => "SGD",
        "nominal_price" => price.to_s, "cost_price" => cost_price, "cost_price_valid" => cost_price_valid,
        "market_val" => (BigDecimal(qty.to_s) * BigDecimal(price.to_s)).to_s("F"), "unrealized_pl" => unrealized_pl
      }.compact
    end

    def trade_entry(deal_id)
      @account.entries.find_by!(external_id: "moomoo_fill_1234567890123456_#{deal_id}", source: "moomoo")
    end

    def fill(deal_id, side:, code:, qty: "1", price: "100", at: Time.utc(2026, 10, 20, 15, 0), status: "OK")
      micros = Provider::Moomoo.to_micros(at)
      {
        "deal_id" => deal_id, "order_id" => "o-#{deal_id}", "trd_side" => side, "code" => code, "stock_name" => code,
        "qty" => qty, "price" => price, "create_time" => micros, "updated_time" => micros, "status" => status
      }
    end

    def positions
      [
        { "position_side" => "LONG", "code" => "HK.00700", "stock_name" => "TENCENT", "security_type" => "STOCK", "qty" => "100", "currency" => "HKD",
          "nominal_price" => "400.000", "cost_price" => "350.000", "cost_price_valid" => true, "market_val" => "40000.00", "unrealized_pl" => "5000.00" },
        { "position_side" => "LONG", "code" => "SG.D05", "stock_name" => "DBS", "security_type" => "STOCK", "qty" => "50", "currency" => "SGD",
          "nominal_price" => "38.500", "cost_price" => "30.000", "cost_price_valid" => false, "market_val" => "1925.00" },
        { "position_side" => "LONG", "code" => "US.AAPL", "stock_name" => "Apple", "security_type" => "STOCK", "qty" => "10", "currency" => "USD",
          "nominal_price" => "180.000", "cost_price" => "150.000", "cost_price_valid" => true, "market_val" => "1800.00", "unrealized_pl" => "300.00" },
        { "position_side" => "SHORT", "code" => "US.STU", "security_type" => "STOCK", "qty" => "5", "currency" => "USD", "market_val" => "1000.00" },
        { "position_side" => "LONG", "code" => "US.AAPL240119C190000", "security_type" => "OPTION", "qty" => "1", "currency" => "USD", "market_val" => "500.00" },
        { "position_side" => "LONG", "code" => "US.MSFT", "security_type" => "STOCK", "qty" => "0", "currency" => "USD", "market_val" => "0.00" }
      ]
    end
end
