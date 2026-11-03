require "test_helper"

class EtoroAccountProcessorTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 10, 24)

    @family = families(:dylan_family)
    @etoro_account = etoro_accounts(:main_account)
    @etoro_account.etoro_item.update!(raw_instruments_payload: {
      "1001" => { "symbol" => "AAPL", "name" => "Apple", "type_id" => 5 },
      "1002" => { "symbol" => "TUVW", "name" => "Tuvw Motors", "type_id" => 5 }
    })
    @etoro_account.update!(
      current_balance: 1500,
      cash_balance: 900,
      raw_positions_payload: [
        position(11, 1001, units: 2, amount: 300, pnl: 50, opened: "2026-03-01T09:00:00Z"),
        position(12, 1001, units: 1, amount: 150, pnl: 10, opened: "2026-04-01T09:00:00Z", mirror: 7),
        position(13, 1002, units: 5, amount: 100, pnl: -20, opened: "2026-06-01T09:00:00Z", settlement: 0)
      ],
      raw_trades_payload: [
        closed_trade(21, 1001, units: 4, investment: 400, net_profit: 40, opened: "2026-01-10T10:00:00Z", closed: "2026-02-10T15:00:00Z"),
        closed_trade(22, 1002, units: 3, investment: 90, net_profit: 9, opened: "2026-01-12T10:00:00Z", closed: "2026-02-12T15:00:00Z", buy: false),
        closed_trade(11, 1001, units: 1, investment: 150, net_profit: 5, opened: "2026-03-01T09:00:00Z", closed: "2026-05-01T12:00:00Z")
      ],
      raw_balance_history_payload: [
        { "date" => "2026-10-22", "total" => "1400", "currency" => "USD" },
        { "date" => "2026-10-23", "total" => "1450", "currency" => "USD" },
        { "date" => "2026-10-24", "total" => "1480", "currency" => "USD" }
      ]
    )

    @account = @family.accounts.create!(
      name: "eToro",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    @etoro_account.ensure_account_provider!(@account)
    # Linked before any day a test travels back to: what a sync writes is
    # never older than the link.
    @etoro_account.account_provider.update_columns(created_at: 1.year.ago)
    @etoro_account.reload

    Security::Resolver.stubs(:new).with("AAPL").returns(stub(resolve: securities(:aapl)))
  end

  test "a balance the anchor refuses leaves the account's figures as they were" do
    @account.update!(balance: 1000, cash_balance: 400)
    Account.any_instance.stubs(:set_current_balance).returns(Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "refused"))

    assert_raises(Provider::Etoro::Error) { EtoroAccount::Processor.new(@etoro_account).process }

    @account.reload
    assert_equal [ BigDecimal("1000"), BigDecimal("400") ], [ @account.balance, @account.cash_balance ]
  end

  test "imports real-asset holdings and counts everything else as cash" do
    assert_equal({ holdings: 1, failed_records: 0 }, process)

    holding = @account.holdings.find_by!(security: securities(:aapl), date: Date.current)
    assert_equal BigDecimal("3"), holding.qty
    assert_equal BigDecimal("510"), holding.amount
    assert_equal BigDecimal("170"), holding.price
    assert_equal BigDecimal("150"), holding.cost_basis
    assert_equal 1, @account.holdings.count

    @account.reload
    assert_equal BigDecimal("1500"), @account.balance
    assert_equal BigDecimal("990"), @account.cash_balance
  end

  test "takes the P&L from the position when eToro puts it there" do
    flat = position(11, 1001, units: 2, amount: 300, pnl: 0, opened: "2026-03-01T09:00:00Z").except("unrealizedPnL").merge("pnL" => 30)
    @etoro_account.update!(raw_positions_payload: [ flat ])

    process

    assert_equal BigDecimal("330"), @account.holdings.find_by!(security: securities(:aapl), date: Date.current).amount
    assert_equal BigDecimal("1170"), @account.reload.cash_balance
  end

  test "lines of one stock on eToro make one holding" do
    listed = Security.create!(ticker: "ABCD", name: "Abcd Corp", exchange_operating_mic: "XNAS")
    @etoro_account.etoro_item.update!(raw_instruments_payload: {
      "2001" => { "symbol" => "ABCD", "type_id" => 5, "exchange_id" => 4 },
      "2002" => { "symbol" => "ABCD.RTH", "type_id" => 5, "exchange_id" => 33 }
    })
    @etoro_account.update!(raw_positions_payload: [
      position(61, 2001, units: 2, amount: 200, pnl: 20, opened: "2026-03-01T09:00:00Z"),
      position(62, 2002, units: 1, amount: 100, pnl: 10, opened: "2026-04-01T09:00:00Z")
    ], raw_trades_payload: [])
    Security::Resolver.stubs(:new).with("ABCD", exchange_operating_mic: "XNAS").returns(stub(resolve: listed))

    process

    holding = @account.holdings.sole
    assert_equal listed, holding.security
    assert_equal BigDecimal("3"), holding.qty
    assert_equal BigDecimal("330"), holding.amount
    assert_equal "etoro_holding_etoro_trading_1_#{listed.id}_2026-10-24", holding.external_id
  end

  test "closing the last real asset closes its holding today" do
    yesterday_holding(securities(:aapl), qty: 3)
    @etoro_account.update!(raw_positions_payload: [ position(13, 1002, units: 5, amount: 100, pnl: -20, opened: "2026-06-01T09:00:00Z", settlement: 0) ])

    process

    assert_equal Date.current, @account.latest_provider_holdings_snapshot_date
    assert_empty @account.current_holdings
    assert_equal BigDecimal("0"), @account.holdings.find_by!(security: securities(:aapl), date: Date.current).qty
    assert_equal 0, Holding::PortfolioSnapshot.new(@account).to_h[securities(:aapl).id]
    assert_equal BigDecimal("1500"), @account.reload.cash_balance
  end

  test "a holding sold since an earlier sync that day is closed" do
    process

    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    @etoro_account.etoro_item.update!(raw_instruments_payload: @etoro_account.instruments_map.merge("1003" => { "symbol" => "MSFT", "type_id" => 5 }))
    @etoro_account.update!(raw_positions_payload: [ position(14, 1003, units: 1, amount: 400, pnl: 0, opened: "2026-10-24T10:00:00Z") ])
    process

    assert_equal BigDecimal("0"), @account.holdings.find_by!(security: securities(:aapl), date: Date.current).qty
    assert_equal [ securities(:msft) ], @account.current_holdings.map(&:security)
  end

  test "a remapped holding that is still held stays open" do
    process
    @account.holdings.find_by!(security: securities(:aapl), date: Date.current)
      .update!(security: securities(:msft), security_locked: true)

    process

    holding = @account.holdings.find_by!(provider_security: securities(:aapl), date: Date.current)
    assert_equal securities(:msft), holding.security
    assert_equal BigDecimal("3"), holding.qty
  end

  test "holdings stay open while an instrument still held awaits eToro's details" do
    yesterday_holding(securities(:aapl), qty: 3)
    @etoro_account.etoro_item.update!(raw_instruments_payload: {})
    warnings = DebugLogEntry.where(level: "warn", provider_key: "etoro")
    warned_before = warnings.count

    process

    assert_nil @account.holdings.find_by(security: securities(:aapl), date: Date.current)
    assert_equal Date.current - 1, @account.latest_provider_holdings_snapshot_date
    assert_equal [ BigDecimal("3") ], @account.current_holdings.map(&:qty)
    assert_equal warned_before + 1, warnings.count
  end

  test "an unreadable positions payload closes nothing" do
    yesterday_holding(securities(:aapl), qty: 3)
    @etoro_account.update!(raw_positions_payload: {})

    process

    assert_equal Date.current - 1, @account.latest_provider_holdings_snapshot_date
  end

  test "a zero-balance account drops to zero with no holdings" do
    yesterday_holding(securities(:aapl), qty: 3)
    @etoro_account.update!(current_balance: 0, cash_balance: 0, raw_positions_payload: [], raw_trades_payload: [], raw_balance_history_payload: [])

    process

    @account.reload
    assert_equal BigDecimal("0"), @account.balance
    assert_equal BigDecimal("0"), @account.cash_balance
    assert_empty @account.current_holdings
  end

  test "turns positions into buys and closes into sells, skipping CFDs" do
    process

    trades = @account.entries.where(source: "etoro", entryable_type: "Trade").index_by(&:external_id)
    partial_close_id = "etoro_position_11_close_#{Time.utc(2026, 5, 1, 12).to_i}"
    full_close_id = "etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}"

    assert_equal [ partial_close_id, "etoro_position_11_open", "etoro_position_12_open", full_close_id, "etoro_position_21_open" ].sort,
      trades.keys.sort

    partly_closed = trades["etoro_position_11_open"]
    assert_equal Date.new(2026, 3, 1), partly_closed.date
    assert_equal BigDecimal("3"), partly_closed.trade.qty
    assert_equal BigDecimal("450"), partly_closed.amount

    sell = trades[full_close_id]
    assert_equal Date.new(2026, 2, 10), sell.date
    assert_equal BigDecimal("-4"), sell.trade.qty
    assert_equal BigDecimal("-440"), sell.amount
    assert_equal BigDecimal("110"), sell.trade.price
  end

  test "the closed legs of a CFD position yield no trades" do
    @etoro_account.update!(raw_trades_payload: @etoro_account.raw_trades_payload + [
      closed_trade(13, 1002, units: 2, investment: 40, net_profit: 4, opened: "2026-06-01T09:00:00Z", closed: "2026-07-01T15:00:00Z")
    ])
    Security::Resolver.expects(:new).with("TUVW").never

    process

    assert_empty @account.entries.where("external_id LIKE ?", "etoro_position_13_%")
  end

  test "a position seen open on an earlier sync as anything but a real asset yields no trades once closed" do
    @etoro_account.update!(
      position_settlement_types: { "31" => 0, "32" => 2 },
      raw_trades_payload: [
        closed_trade(31, 1001, units: 2, investment: 300, net_profit: 30, opened: "2026-01-05T10:00:00Z", closed: "2026-03-05T15:00:00Z"),
        closed_trade(32, 1001, units: 1, investment: 150, net_profit: 5, opened: "2026-01-06T10:00:00Z", closed: "2026-03-06T15:00:00Z")
      ]
    )

    process

    assert_empty @account.entries.where("external_id LIKE ? OR external_id LIKE ?", "etoro_position_31_%", "etoro_position_32_%")
  end

  test "an unleveraged long on an instrument eToro offers only as a CFD yields no trades" do
    @etoro_account.etoro_item.update!(raw_instruments_payload: @etoro_account.instruments_map.merge(
      "1004" => { "symbol" => "CMDA", "name" => "Commodity A", "type_id" => 2 },
      "1005" => { "symbol" => "IDX500", "name" => "Index 500", "type_id" => 4 }
    ))
    @etoro_account.update!(raw_trades_payload: [
      closed_trade(41, 1004, units: 1, investment: 100, net_profit: 12, opened: "2026-03-02T10:00:00Z", closed: "2026-06-15T14:00:00Z"),
      closed_trade(42, 1005, units: 1, investment: 200, net_profit: 2, opened: "2026-03-03T10:00:00Z", closed: "2026-06-16T14:00:00Z")
    ])

    process

    assert_empty @account.entries.where("external_id LIKE ? OR external_id LIKE ?", "etoro_position_41_%", "etoro_position_42_%")
  end

  test "an instrument eToro has not described yet waits for a later sync" do
    @etoro_account.update!(
      raw_positions_payload: [ position(51, 1003, units: 1, amount: 400, pnl: 0, opened: "2026-09-01T10:00:00Z") ],
      raw_trades_payload: [ closed_trade(52, 1003, units: 1, investment: 380, net_profit: 20, opened: "2026-08-01T10:00:00Z", closed: "2026-08-20T10:00:00Z") ]
    )

    process

    assert_empty @account.holdings
    assert_empty @account.entries.where(entryable_type: "Trade")
    assert_equal BigDecimal("1500"), @account.reload.cash_balance

    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    @etoro_account.etoro_item.update!(raw_instruments_payload: @etoro_account.instruments_map.merge("1003" => { "symbol" => "MSFT", "type_id" => 5 }))
    process

    assert_equal [ "etoro_position_51_open", "etoro_position_52_close_#{Time.utc(2026, 8, 20, 10).to_i}", "etoro_position_52_open" ],
      @account.entries.where(entryable_type: "Trade").pluck(:external_id).sort
    assert_equal [ securities(:msft) ], @account.current_holdings.map(&:security)
  end

  test "stored closes are left alone while the buys of open positions follow eToro" do
    process

    @etoro_account.update!(
      raw_positions_payload: @etoro_account.raw_positions_payload.map { |open| open["positionID"] == 11 ? open.merge("units" => 4, "unitsBaseValueDollars" => 600) : open },
      raw_trades_payload: @etoro_account.raw_trades_payload.map { |closed| closed.merge("netProfit" => 999) }
    )
    process

    trades = @account.entries.where(source: "etoro", entryable_type: "Trade").index_by(&:external_id)
    assert_equal BigDecimal("-440"), trades["etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}"].amount
    assert_equal BigDecimal("4"), trades["etoro_position_21_open"].trade.qty
    assert_equal BigDecimal("5"), trades["etoro_position_11_open"].trade.qty
  end

  test "a second run rewrites only the buys of open positions" do
    process

    assert_equal({ buys: 2, sells: 0 }, EtoroAccount::ActivitiesProcessor.new(@etoro_account.reload).process)
  end

  test "the buy of a position closed after a sync that missed a partial close is rebuilt from its closes" do
    @etoro_account.update!(
      raw_positions_payload: [ position(71, 1001, units: 6, amount: 600, pnl: 0, opened: "2026-10-05T10:00:00Z") ],
      raw_trades_payload: []
    )
    process

    @etoro_account.update!(raw_positions_payload: [], raw_trades_payload: [
      closed_trade(71, 1001, units: 6, investment: 600, net_profit: 30, opened: "2026-10-05T10:00:00Z", closed: "2026-10-20T15:00:00Z"),
      closed_trade(71, 1001, units: 4, investment: 400, net_profit: 20, opened: "2026-10-05T10:00:00Z", closed: "2026-10-10T15:00:00Z")
    ])
    process

    buy = trade_entry("etoro_position_71_open")
    assert_equal BigDecimal("10"), buy.trade.qty
    assert_equal BigDecimal("1000"), buy.amount
    assert_equal BigDecimal("0"), position_trades(71).sum { |entry| entry.trade.qty }
  end

  test "a buy counted twice while its close was already in the history is rebuilt once the position is gone" do
    @etoro_account.update!(
      raw_positions_payload: [ position(72, 1001, units: 10, amount: 1000, pnl: 0, opened: "2026-10-05T10:00:00Z") ],
      raw_trades_payload: [ closed_trade(72, 1001, units: 10, investment: 1000, net_profit: 50, opened: "2026-10-05T10:00:00Z", closed: "2026-10-23T15:00:00Z") ]
    )
    process
    assert_equal BigDecimal("20"), trade_entry("etoro_position_72_open").trade.qty

    @etoro_account.update!(raw_positions_payload: [])
    process

    buy = trade_entry("etoro_position_72_open")
    assert_equal BigDecimal("10"), buy.trade.qty
    assert_equal BigDecimal("1000"), buy.amount
  end

  test "a relinked account keeps the buys of positions with closes older than its trade history" do
    late_close = closed_trade(81, 1001, units: 6, investment: 600, net_profit: 60, opened: "2025-06-02T10:00:00Z", closed: "2026-08-20T15:00:00Z")
    @etoro_account.update!(
      raw_positions_payload: [ position(82, 1001, units: 5, amount: 500, pnl: 0, opened: "2025-07-01T10:00:00Z") ],
      raw_trades_payload: [
        closed_trade(81, 1001, units: 4, investment: 400, net_profit: 40, opened: "2025-06-02T10:00:00Z", closed: "2026-02-10T15:00:00Z"),
        late_close,
        closed_trade(82, 1001, units: 3, investment: 300, net_profit: 30, opened: "2025-07-01T10:00:00Z", closed: "2026-01-15T15:00:00Z")
      ]
    )
    process

    # A new connection linked to the same account starts from the trades
    # closed within its window.
    travel_to Date.new(2027, 4, 24)
    @etoro_account.update!(raw_trades_payload: [ late_close ])
    process

    closed_buy = trade_entry("etoro_position_81_open")
    open_buy = trade_entry("etoro_position_82_open")
    assert_equal [ BigDecimal("10"), BigDecimal("1000") ], [ closed_buy.trade.qty, closed_buy.amount ]
    assert_equal [ BigDecimal("8"), BigDecimal("800") ], [ open_buy.trade.qty, open_buy.amount ]
    assert_equal BigDecimal("0"), position_trades(81).sum { |entry| entry.trade.qty }
    assert_equal BigDecimal("5"), position_trades(82).sum { |entry| entry.trade.qty }
    assert_equal({ buys: 0, sells: 0 }, EtoroAccount::ActivitiesProcessor.new(@etoro_account.reload).process)
  end

  test "a rename moves all of a position's trades, closes older than the trade history included" do
    early_close_id = "etoro_position_81_close_#{Time.utc(2026, 2, 10, 15).to_i}"
    late_close = closed_trade(81, 1001, units: 6, investment: 600, net_profit: 60, opened: "2025-06-02T10:00:00Z", closed: "2026-08-20T15:00:00Z")
    @etoro_account.update!(raw_positions_payload: [], raw_trades_payload: [
      closed_trade(81, 1001, units: 4, investment: 400, net_profit: 40, opened: "2025-06-02T10:00:00Z", closed: "2026-02-10T15:00:00Z"),
      late_close
    ])
    process

    travel_to Date.new(2027, 4, 24)
    @etoro_account.update!(raw_trades_payload: [ late_close ])
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    process

    trades = position_trades(81).to_a
    assert_equal 3, trades.size
    assert_equal [ securities(:msft) ], trades.map { |entry| entry.trade.security }.uniq
    assert_equal BigDecimal("10"), trade_entry("etoro_position_81_open").trade.qty
    assert_equal [ Date.new(2026, 2, 10), BigDecimal("-4"), BigDecimal("-440") ],
      [ trade_entry(early_close_id).date, trade_entry(early_close_id).trade.qty, trade_entry(early_close_id).amount ]
  end

  test "a stored trade dated on another day is dated again" do
    process
    close_id = "etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}"
    [ "etoro_position_21_open", close_id ].each { |external_id| trade_entry(external_id).update!(date: trade_entry(external_id).date + 1) }

    EtoroAccount::ActivitiesProcessor.new(@etoro_account.reload).process

    assert_equal Date.new(2026, 1, 10), trade_entry("etoro_position_21_open").date
    assert_equal Date.new(2026, 2, 10), trade_entry(close_id).date
  end

  test "a renamed instrument moves its stored trades and holding to the new security" do
    process

    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    @etoro_account.etoro_item.update!(raw_instruments_payload: @etoro_account.instruments_map.merge("1001" => { "symbol" => "MSFT", "name" => "Microsoft", "type_id" => 5 }))
    process

    trades = @account.entries.where(source: "etoro", entryable_type: "Trade").includes(:entryable).to_a
    assert_equal 5, trades.size
    assert_equal [ securities(:msft) ], trades.map { |entry| entry.trade.security }.uniq
    assert_equal [ securities(:msft) ], @account.current_holdings.map(&:security)
  end

  test "with its own securities, the trades and holdings move to eToro's own securities, and the securities only they used go" do
    qrst = Security.create!(ticker: "QRST", name: "Qrst", exchange_operating_mic: "XNYS", offline: true)
    Security::Price.create!(security: qrst, date: Date.new(2026, 2, 20), price: 310, currency: "USD")
    Security::Resolver.stubs(:new).with("QRST", exchange_operating_mic: "XNYS").returns(stub(resolve: qrst))
    describe_instrument(1003, "symbol" => "QRST", "name" => "Qrst", "type_id" => 5, "exchange_id" => 5)
    @etoro_account.update!(raw_trades_payload: @etoro_account.raw_trades_payload +
      [ closed_trade(23, 1003, units: 1, investment: 300, net_profit: 10, opened: "2026-02-01T10:00:00Z", closed: "2026-02-20T15:00:00Z") ])
    process
    assert_equal [ "AAPL", "QRST" ], @account.trades.map { |trade| trade.security.ticker }.uniq.sort

    @etoro_account.etoro_item.update!(own_securities: true)
    process

    assert_equal [ "ETORO:AAPL", "ETORO:QRST" ], @account.trades.reload.map { |trade| trade.security.ticker }.uniq.sort
    assert_equal [ "ETORO:AAPL" ], @account.current_holdings.map { |holding| holding.security.ticker }
    own = Security.find_by!(ticker: "ETORO:QRST", exchange_operating_mic: "XNYS")
    assert_equal [ true, EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, "Qrst" ], [ own.offline?, own.offline_reason, own.name ]
    assert_not Security.exists?(qrst.id), "the security only eToro's trades used goes"
    assert_empty Security::Price.where(security_id: qrst.id)
    assert Security.exists?(securities(:aapl).id), "a security other accounts use stays"

    Security::Price.create!(security: own, date: Date.new(2026, 2, 20), price: 300, currency: "USD")
    found_again = Security.create!(ticker: "QRST", name: "Qrst", exchange_operating_mic: "XNYS", offline: true)
    Security::Resolver.stubs(:new).with("QRST", exchange_operating_mic: "XNYS").returns(stub(resolve: found_again))
    @etoro_account.etoro_item.update!(own_securities: false)
    process

    assert_equal [ "AAPL", "QRST" ], @account.trades.reload.map { |trade| trade.security.ticker }.uniq.sort
    assert_not Security.exists?(own.id), "eToro's own security goes with its prices once nothing uses it"
    assert_nil Security.find_by(ticker: "ETORO:AAPL")
  end

  test "a security eToro's trades leave stays while another account holds it" do
    qrst = Security.create!(ticker: "QRST", name: "Qrst", exchange_operating_mic: "XNYS", offline: true)
    Security::Resolver.stubs(:new).with("QRST", exchange_operating_mic: "XNYS").returns(stub(resolve: qrst))
    describe_instrument(1003, "symbol" => "QRST", "name" => "Qrst", "type_id" => 5, "exchange_id" => 5)
    @etoro_account.update!(raw_trades_payload: @etoro_account.raw_trades_payload +
      [ closed_trade(23, 1003, units: 1, investment: 300, net_profit: 10, opened: "2026-02-01T10:00:00Z", closed: "2026-02-20T15:00:00Z") ])
    process
    Holding.create!(account: accounts(:investment), security: qrst, date: Date.current, qty: 1, price: 300, amount: 300, currency: "USD")

    @etoro_account.etoro_item.update!(own_securities: true)
    process

    assert Security.exists?(qrst.id)
    assert_equal [ "ETORO:AAPL", "ETORO:QRST" ], @account.trades.reload.map { |trade| trade.security.ticker }.uniq.sort
  end

  test "a rename moves the holdings eToro reported on earlier days to the new security" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1003, "symbol" => "MSFT", "name" => "Microsoft", "type_id" => 5)
    @etoro_account.update!(raw_trades_payload: @etoro_account.raw_trades_payload +
      [ closed_trade(23, 1003, units: 1, investment: 300, net_profit: 10, opened: "2026-02-01T10:00:00Z", closed: "2026-02-20T15:00:00Z") ])
    travel_to Date.new(2026, 10, 22)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    process
    materialize

    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.new(2026, 10, 24)
    assert_empty @account.holdings.where(security: securities(:aapl))
    reported = @account.holdings.find_by!(security: securities(:msft), date: Date.new(2026, 10, 22))
    assert_equal [ BigDecimal("3"), BigDecimal("510") ], [ reported.qty, reported.amount ]

    balance = @account.balances.find_by!(date: Date.new(2026, 10, 22))
    assert_equal [ BigDecimal("510"), BigDecimal("890") ], [ balance.end_non_cash_balance, balance.end_cash_balance ]
  end

  test "a rename seen later in the day also drops the old security's holding of that day" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    travel_to Time.utc(2026, 10, 23, 12)
    process
    materialize
    travel_to Time.utc(2026, 10, 24, 9)
    process
    materialize

    travel_to Time.utc(2026, 10, 24, 18)
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    process
    materialize

    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.new(2026, 10, 24)
    assert_empty @account.holdings.where(security: securities(:aapl))
    assert_equal [ Date.new(2026, 10, 23), Date.new(2026, 10, 24) ],
      @account.holdings.where(security: securities(:msft)).where.not(account_provider_id: nil).order(:date).pluck(:date)
  end

  test "a rename seen while another instrument awaits eToro's details holds the units once today" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    travel_to Time.utc(2026, 10, 24, 9)
    process

    travel_to Time.utc(2026, 10, 24, 18)
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(15, 1009, units: 1, amount: 50, pnl: 0, opened: "2026-10-24T12:00:00Z") ])
    process

    assert_equal({ "MSFT" => BigDecimal("3") }, reported_quantities(Date.current))
  end

  test "a line that now resolves to another line's security adds its earlier holdings to that line's" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1003, "symbol" => "MSFT", "type_id" => 5)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1003, "symbol" => "AAPL.RTH", "exchange_id" => 33)
    process
    materialize

    assert_held_once BigDecimal("5"), Date.new(2026, 6, 1)..Date.new(2026, 10, 24)
    assert_empty @account.holdings.where(security: securities(:msft))
    reported = @account.holdings.find_by!(security: securities(:aapl), date: Date.new(2026, 10, 23))
    assert_equal [ BigDecimal("5"), BigDecimal("850") ], [ reported.qty, reported.amount ]
  end

  test "a security another instrument is still held on keeps its earlier holdings" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1003, "symbol" => "AAPL.RTH", "name" => "Apple", "type_id" => 5, "exchange_id" => 33)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1003, "symbol" => "MSFT", "exchange_id" => nil)
    process

    assert_equal BigDecimal("5"), @account.holdings.find_by!(security: securities(:aapl), date: Date.new(2026, 10, 23)).qty
    assert_nil @account.holdings.find_by(security: securities(:msft), date: Date.new(2026, 10, 23))
  end

  test "a security whose instruments now resolve to different securities keeps its earlier holdings" do
    mnop = Security.create!(ticker: "MNOP", name: "Mnop Inc", exchange_operating_mic: "XNAS")
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    Security::Resolver.stubs(:new).with("MNOP").returns(stub(resolve: mnop))
    describe_instrument(1003, "symbol" => "AAPL.RTH", "name" => "Apple", "type_id" => 5, "exchange_id" => 33)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1001, "symbol" => "MSFT")
    describe_instrument(1003, "symbol" => "MNOP", "exchange_id" => nil)
    process

    assert_equal BigDecimal("5"), @account.holdings.find_by!(security: securities(:aapl), date: Date.new(2026, 10, 23)).qty
    assert_empty @account.holdings.where(security: [ securities(:msft), mnop ], date: Date.new(2026, 10, 23))
  end

  test "a security whose instruments now resolve to different securities leaves no calculated history behind" do
    mnop = Security.create!(ticker: "MNOP", name: "Mnop Inc", exchange_operating_mic: "XNAS")
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    Security::Resolver.stubs(:new).with("MNOP").returns(stub(resolve: mnop))
    describe_instrument(1003, "symbol" => "AAPL.RTH", "name" => "Apple", "type_id" => 5, "exchange_id" => 33)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1001, "symbol" => "MSFT")
    describe_instrument(1003, "symbol" => "MNOP", "exchange_id" => nil)
    process
    materialize

    assert_empty @account.holdings.where(security: securities(:aapl), account_provider_id: nil)
    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.new(2026, 5, 31)
    assert_held_once BigDecimal("5"), Date.new(2026, 6, 1)..Date.new(2026, 10, 22)
    assert_held_once BigDecimal("5"), Date.current..Date.current
    # eToro's holding of the day before cannot be split between the two.
    assert_equal({ "AAPL" => BigDecimal("5") }, reported_quantities(Date.new(2026, 10, 23)))
  end

  test "a security that still has trades of a position eToro no longer lists keeps its earlier holdings" do
    @etoro_account.update!(
      raw_positions_payload: [ position(96, 1001, units: 3, amount: 300, pnl: 0, opened: "2026-03-01T09:00:00Z") ],
      raw_trades_payload: [ closed_trade(95, 1001, units: 2, investment: 200, net_profit: 20, opened: "2025-08-01T10:00:00Z", closed: "2025-10-30T15:00:00Z") ]
    )
    travel_to Date.new(2026, 10, 23)
    process

    # A new connection linked to the same account starts its trade history
    # after position 95 closed.
    travel_to Date.new(2026, 10, 24)
    @etoro_account.update!(raw_trades_payload: [])
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    process

    assert_equal({ "AAPL" => BigDecimal("3") }, reported_quantities(Date.new(2026, 10, 23)))
    assert_equal [ securities(:aapl) ], position_trades(95).map { |entry| entry.trade.security }.uniq
  end

  test "instruments that swap tickers leave the earlier holdings where they were" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1003, "symbol" => "MSFT", "name" => "Microsoft", "type_id" => 5)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1001, "symbol" => "MSFT")
    describe_instrument(1003, "symbol" => "AAPL")
    process
    materialize

    assert_equal({ "AAPL" => BigDecimal("3"), "MSFT" => BigDecimal("2") }, reported_quantities(Date.new(2026, 10, 23)))
    assert_equal({ "AAPL" => BigDecimal("2"), "MSFT" => BigDecimal("3") }, reported_quantities(Date.current))
    assert_held_once BigDecimal("5"), Date.new(2026, 6, 1)..Date.new(2026, 10, 24)
  end

  test "holdings a user moved to another security stay there" do
    mnop = Security.create!(ticker: "MNOP", name: "Mnop Inc", exchange_operating_mic: "XNAS")
    travel_to Date.new(2026, 10, 23)
    process
    @account.holdings.find_by!(security: securities(:aapl), date: Date.current).remap_security!(mnop)

    travel_to Date.new(2026, 10, 24)
    process

    moved = @account.holdings.where(security: mnop).order(:date)
    assert_equal [ Date.new(2026, 10, 23), Date.new(2026, 10, 24) ], moved.pluck(:date)
    assert moved.all?(&:security_locked?)
    assert_equal [ BigDecimal("3") ], moved.map(&:qty).uniq
  end

  test "trades stay with a holding a user moved to another security" do
    mnop = Security.create!(ticker: "MNOP", name: "Mnop Inc", exchange_operating_mic: "XNAS")
    travel_to Date.new(2026, 10, 23)
    process
    materialize
    @account.holdings.find_by!(security: securities(:aapl), date: Date.current).remap_security!(mnop)
    materialize

    travel_to Date.new(2026, 10, 24)
    process
    materialize

    assert_equal [ mnop ], @account.trades.reload.map(&:security).uniq
    assert_empty @account.holdings.where(security: securities(:aapl))
    assert_held_once BigDecimal("4"), Date.new(2026, 1, 10)..Date.new(2026, 2, 9)
    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.current
  end

  test "a holding a user moved follows its instrument to a new security" do
    mnop = Security.create!(ticker: "MNOP", name: "Mnop Inc", exchange_operating_mic: "XNAS")
    travel_to Date.new(2026, 10, 22)
    process
    materialize
    @account.holdings.find_by!(security: securities(:aapl), date: Date.current).remap_security!(mnop)
    travel_to Date.new(2026, 10, 23)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1001, "symbol" => "MSFT", "name" => "Microsoft")
    process
    materialize

    assert_empty @account.holdings.where(security: mnop)
    assert_equal [ securities(:msft) ], @account.trades.reload.map(&:security).uniq
    assert_held_once BigDecimal("4"), Date.new(2026, 1, 10)..Date.new(2026, 2, 9)
    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.current
    reported = @account.holdings.where(security: securities(:msft)).where.not(account_provider_id: nil).order(:date)
    assert_equal [ Date.new(2026, 10, 22), Date.new(2026, 10, 23), Date.new(2026, 10, 24) ], reported.pluck(:date)
    assert_not reported.any?(&:security_locked?)
  end

  test "holdings a user merged into a security whose trades all leave go with them" do
    Security::Resolver.stubs(:new).with("MSFT").returns(stub(resolve: securities(:msft)))
    describe_instrument(1003, "symbol" => "MSFT", "name" => "Microsoft", "type_id" => 5)
    @etoro_account.update!(raw_positions_payload: @etoro_account.raw_positions_payload +
      [ position(14, 1003, units: 2, amount: 300, pnl: 40, opened: "2026-06-01T09:00:00Z") ])
    travel_to Date.new(2026, 10, 23)
    process
    materialize
    @account.holdings.find_by!(security: securities(:aapl), date: Date.current).remap_security!(securities(:msft))
    materialize

    travel_to Date.new(2026, 10, 24)
    describe_instrument(1003, "symbol" => "AAPL.RTH", "exchange_id" => 33)
    process
    materialize

    assert_empty @account.holdings.where(security: securities(:msft))
    assert_held_once BigDecimal("3"), Date.new(2026, 5, 1)..Date.new(2026, 5, 31)
    assert_held_once BigDecimal("5"), Date.new(2026, 6, 1)..Date.current
    reported = @account.holdings.find_by!(security: securities(:aapl), date: Date.new(2026, 10, 23))
    assert_equal [ BigDecimal("5"), BigDecimal("850") ], [ reported.qty, reported.amount ]
  end

  test "an instrument resolves once a run, so a lookup failing after the holdings import moves nothing" do
    travel_to Date.new(2026, 10, 23)
    process
    materialize

    travel_to Date.new(2026, 10, 24)
    resolver = stub
    resolver.stubs(:resolve).returns(securities(:aapl)).then.raises(Timeout::Error, "provider timeout")
    Security::Resolver.stubs(:new).with("AAPL").returns(resolver)
    process
    materialize

    assert_equal({ "AAPL" => BigDecimal("3") }, reported_quantities(Date.current))
    assert_equal [ securities(:aapl) ], @account.trades.reload.map(&:security).uniq
  end

  test "a run in a zone ahead of UTC dates everything by eToro's UTC day" do
    travel_to Time.utc(2026, 10, 24, 20)
    @etoro_account.update!(raw_trades_payload: [
      closed_trade(21, 1001, units: 4, investment: 400, net_profit: 40, opened: "2026-01-10T17:00:00Z", closed: "2026-10-24T19:00:00Z")
    ])

    Time.use_zone("Asia/Singapore") { process }

    today = Date.new(2026, 10, 24)
    assert_equal today, @account.reload.current_anchor_date
    assert_equal [ today ], @account.holdings.distinct.pluck(:date)
    assert @account.holdings.all? { |holding| holding.external_id.end_with?("_2026-10-24") }
    assert_equal Date.new(2026, 1, 10), trade_entry("etoro_position_21_open").date
    assert_equal today, trade_entry("etoro_position_21_close_#{Time.utc(2026, 10, 24, 19).to_i}").date
  end

  test "a leg closed before a split goes on today's shares, for the same money" do
    describe_instrument(1001, "price_history" => { "splits" => [ [ "2026-03-02", "2" ] ] })

    process

    buy = trade_entry("etoro_position_21_open")
    sell = trade_entry("etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}")
    assert_equal [ BigDecimal("8"), BigDecimal("400") ], [ buy.trade.qty, buy.amount ]
    assert_equal [ BigDecimal("-8"), BigDecimal("-440"), BigDecimal("55") ], [ sell.trade.qty, sell.amount, sell.trade.price ]
  end

  test "eToro's restated open legs and the legs closed after a split stay as eToro reports them" do
    describe_instrument(1001, "price_history" => { "splits" => [ [ "2026-03-02", "2" ] ] })

    process

    assert_equal BigDecimal("3"), trade_entry("etoro_position_11_open").trade.qty
    assert_equal BigDecimal("-1"), trade_entry("etoro_position_11_close_#{Time.utc(2026, 5, 1, 12).to_i}").trade.qty
  end

  test "a position closed partly before a split and partly after is held on today's shares throughout" do
    @etoro_account.update!(
      raw_positions_payload: [ position(31, 1001, units: 6, amount: 300, pnl: 0, opened: "2026-01-05T15:00:00Z") ],
      raw_trades_payload: [
        closed_trade(31, 1001, units: 2, investment: 200, net_profit: 20, opened: "2026-01-05T15:00:00Z", closed: "2026-02-02T15:00:00Z"),
        closed_trade(31, 1001, units: 4, investment: 200, net_profit: 40, opened: "2026-01-05T15:00:00Z", closed: "2026-04-01T15:00:00Z")
      ]
    )
    describe_instrument(1001, "price_history" => { "splits" => [ [ "2026-03-02", "2" ] ] })

    process
    materialize

    assert_equal [ BigDecimal("14"), BigDecimal("700") ], [ trade_entry("etoro_position_31_open").trade.qty, trade_entry("etoro_position_31_open").amount ]
    assert_held_once BigDecimal("14"), Date.new(2026, 1, 5)..Date.new(2026, 2, 1)
    assert_held_once BigDecimal("10"), Date.new(2026, 2, 2)..Date.new(2026, 3, 31)
    assert_held_once BigDecimal("6"), Date.new(2026, 4, 1)..Date.current
  end

  test "a leg closed on the day eToro's prices switch goes on the shares its price was on" do
    # eToro's raw closes are on the new shares from 10 February, closing at 55.
    describe_instrument(1001, "price_history" => { "splits" => [ [ "2026-02-10", "2", "55" ] ] })
    before_switch = closed_trade(21, 1001, units: 4, investment: 400, net_profit: 40, opened: "2026-01-10T10:00:00Z", closed: "2026-02-10T15:00:00Z")
    after_switch = closed_trade(23, 1001, units: 2, investment: 100, net_profit: 10, opened: "2026-01-10T10:00:00Z", closed: "2026-02-10T21:30:00Z")
    @etoro_account.update!(raw_trades_payload: [ before_switch.merge("closeRate" => 110), after_switch.merge("closeRate" => 55) ])

    process

    assert_equal BigDecimal("-8"), trade_entry("etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}").trade.qty
    assert_equal BigDecimal("-2"), trade_entry("etoro_position_23_close_#{Time.utc(2026, 2, 10, 21, 30).to_i}").trade.qty
  end

  test "a split found after a relink keeps a position with closes older than the trade history adding up" do
    late_close = closed_trade(81, 1001, units: 6, investment: 600, net_profit: 60, opened: "2025-03-03T10:00:00Z", closed: "2025-11-03T15:00:00Z")
    @etoro_account.update!(raw_positions_payload: [], raw_trades_payload: [
      closed_trade(81, 1001, units: 4, investment: 400, net_profit: 40, opened: "2025-03-03T10:00:00Z", closed: "2025-06-02T15:00:00Z"),
      late_close
    ])
    process

    # A new connection's trade history starts after the first close, and
    # eToro's prices show a split since the second.
    @etoro_account.update!(raw_trades_payload: [ late_close ])
    describe_instrument(1001, "price_history" => { "splits" => [ [ "2025-11-17", "2" ] ] })
    process

    assert_equal [ BigDecimal("16"), BigDecimal("1000") ], [ trade_entry("etoro_position_81_open").trade.qty, trade_entry("etoro_position_81_open").amount ]
    assert_equal BigDecimal("-12"), trade_entry("etoro_position_81_close_#{Time.utc(2025, 11, 3, 15).to_i}").trade.qty
    assert_equal BigDecimal("0"), position_trades(81).sum { |entry| entry.trade.qty }
    assert_equal({ buys: 0, sells: 0 }, EtoroAccount::ActivitiesProcessor.new(@etoro_account.reload).process)
  end

  test "a split found after the trades were stored puts them on today's shares" do
    process
    assert_equal BigDecimal("4"), trade_entry("etoro_position_21_open").trade.qty

    describe_instrument(1001, "price_history" => { "splits" => [ [ "2026-03-02", "2" ] ] })
    process

    assert_equal BigDecimal("8"), trade_entry("etoro_position_21_open").trade.qty
    assert_equal BigDecimal("-8"), trade_entry("etoro_position_21_close_#{Time.utc(2026, 2, 10, 15).to_i}").trade.qty
    assert_equal({ buys: 2, sells: 0 }, EtoroAccount::ActivitiesProcessor.new(@etoro_account.reload).process)
  end

  test "records past daily balances as eToro reconciliations once" do
    2.times { EtoroAccount::Processor.new(@etoro_account.reload).process }

    reconciliations = @account.valuations.reconciliation.joins(:entry).order("entries.date").pluck("entries.date", "entries.amount", "entries.source")
    assert_equal [
      [ Date.new(2026, 10, 22), BigDecimal("1400"), "etoro" ],
      [ Date.new(2026, 10, 23), BigDecimal("1450"), "etoro" ]
    ], reconciliations

    assert_equal Date.current, @account.current_anchor_date
    assert_equal BigDecimal("1500"), @account.current_anchor_balance
  end

  test "linking a manual account lets eToro's figure replace a balance recorded by hand on a day it reports, and keeps the others" do
    opening = @account.entries.create!(date: Date.new(2026, 10, 18), name: "Opening balance", amount: 1000, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))
    before = @account.entries.create!(date: Date.new(2026, 10, 19), name: "Balance update", amount: 1010, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))
    own = @account.entries.create!(date: Date.new(2026, 10, 22), name: "Balance update", amount: 999, currency: "USD", entryable: Valuation.new(kind: "reconciliation"))
    [ opening, before, own ].each { |entry| entry.update_columns(created_at: 2.years.ago) }
    @etoro_account.update!(raw_balance_history_payload: [
      { "date" => "2026-10-18", "total" => "1300", "currency" => "USD" },
      { "date" => "2026-10-22", "total" => "1400", "currency" => "USD" },
      { "date" => "2026-10-23", "total" => "1450", "currency" => "USD" }
    ])

    2.times { process }

    assert_equal [ BigDecimal("1000"), nil ], [ opening.reload.amount, opening.source ], "the opening anchor is the account's start"
    assert_equal [ BigDecimal("1010"), nil ], [ before.reload.amount, before.source ], "a day eToro does not report keeps the balance recorded"
    assert_equal [ BigDecimal("1400"), "etoro" ], [ own.reload.amount, own.source ]
    assert_equal [ [ Date.new(2026, 10, 22), BigDecimal("1400") ], [ Date.new(2026, 10, 23), BigDecimal("1450") ] ],
      @account.entries.where(source: "etoro", entryable_type: "Valuation").order(:date).pluck(:date, :amount)
    assert_equal 1, @account.entries.where(date: Date.new(2026, 10, 22), entryable_type: "Valuation").count
  end

  private

    def process
      EtoroAccount::Processor.new(@etoro_account.reload).process
    end

    # What an account sync does after processing.
    def materialize
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    def describe_instrument(instrument_id, details)
      item = @etoro_account.etoro_item.reload
      instruments = item.instruments_map.deep_dup
      instruments[instrument_id.to_s] = instruments.fetch(instrument_id.to_s, {}).merge(details).compact
      item.update!(raw_instruments_payload: instruments)
    end

    def reported_quantities(date)
      @account.holdings.where(date: date).where.not(account_provider_id: nil).includes(:security).to_h { |holding| [ holding.ticker, holding.qty ] }
    end

    def assert_held_once(quantity, dates)
      held = @account.holdings.where(date: dates).group(:date).sum(:qty)
      wrong = dates.to_h { |date| [ date, held[date] ] }.reject { |_date, held_quantity| held_quantity == quantity }
      assert_empty wrong, "days not holding #{quantity.to_s("F")} units in all"
    end

    def trade_entry(external_id)
      @account.entries.find_by!(source: "etoro", external_id: external_id)
    end

    def position_trades(position_id)
      @account.entries.where(source: "etoro").where("external_id LIKE ?", "etoro\\_position\\_#{position_id}\\_%").includes(:entryable)
    end

    def yesterday_holding(security, qty:)
      Holding.create!(
        account: @account,
        security: security,
        provider_security: security,
        date: Date.current - 1,
        qty: qty,
        price: 150,
        amount: qty * 150,
        currency: "USD",
        account_provider_id: @etoro_account.account_provider.id
      )
    end

    def position(id, instrument_id, units:, amount:, pnl:, opened:, mirror: 0, settlement: 1)
      {
        "positionID" => id,
        "instrumentID" => instrument_id,
        "mirrorID" => mirror,
        "isBuy" => true,
        "leverage" => 1,
        "units" => units,
        "amount" => amount,
        "unitsBaseValueDollars" => amount,
        "openDateTime" => opened,
        "settlementTypeID" => settlement,
        "unrealizedPnL" => { "pnL" => pnl }
      }
    end

    def closed_trade(id, instrument_id, units:, investment:, net_profit:, opened:, closed:, buy: true)
      {
        "positionId" => id,
        "instrumentId" => instrument_id,
        "isBuy" => buy,
        "leverage" => 1,
        "units" => units,
        "investment" => investment,
        "netProfit" => net_profit,
        "openTimestamp" => opened,
        "closeTimestamp" => closed
      }
    end
end
