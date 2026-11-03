require "test_helper"

# A trading account split by currency into cash accounts and stocks
# accounts: the stocks account holds the trades and holdings, the cash
# account the cash log, and each trade is paid from the cash account.
class MoomooAccount::CashSplitTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @family = families(:dylan_family)
    @primary = moomoo_accounts(:main_account)
    # 4,000 SGD in, 2,600 SGD exchanged for 2,000 USD, 12 shares bought for
    # 1,800 USD with a 1 USD fee, 2 sold for 340 USD, a 2 USD dividend.
    @primary.update!(
      role: "cash", current_balance: 1400, cash_balance: 1400, last_seen_at: Time.current, last_positions_sync: Time.current,
      raw_positions_payload: positions, raw_fills_payload: fills, raw_orders_payload: orders, raw_cash_logs_payload: cash_logs
    )
    @sgd_cash = create_account("moomoo SGD cash", "SGD")
    @primary.ensure_account_provider!(@sgd_cash)
    @usd_stocks_row = currency_row("stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    @usd_stocks = link(@usd_stocks_row, "moomoo USD stocks")

    Security::Resolver.stubs(:new).returns(stub(resolve: securities(:aapl)))
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: Date.current, rate: 1.3)
  end

  test "trades and holdings go to the stocks account, the cash log to the cash accounts" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")

    process_all

    assert_equal %w[moomoo_fill_1234567890123456_b1 moomoo_fill_1234567890123456_s1], @usd_stocks.entries.where(entryable_type: "Trade").order(:external_id).pluck(:external_id)
    assert_equal [ "AAPL" ], @usd_stocks.holdings.where.not(account_provider_id: nil).includes(:security).map { |holding| holding.security.ticker }
    assert_equal settlement_ids("stocks"), @usd_stocks.entries.where(entryable_type: "Transaction").order(:external_id).pluck(:external_id)

    assert_not usd_cash.entries.where(entryable_type: "Trade").exists?
    assert_not usd_cash.holdings.exists?
    assert_equal [ "Cash Dividend ACME", "Currency Exchange", "Stock Buy Fee" ], cash_log_names(usd_cash)
    assert_equal settlement_ids("cash"), usd_cash.entries.where("external_id LIKE 'moomoo_settlement_%'").order(:external_id).pluck(:external_id)
    assert_equal [ "Bank Transfer Deposits", "Currency Exchange" ], cash_log_names(@sgd_cash)

    assert_equal [ BigDecimal("1800"), BigDecimal("0") ], [ @usd_stocks.reload.balance, @usd_stocks.cash_balance ]
    assert_equal [ BigDecimal("541"), BigDecimal("541") ], [ usd_cash.reload.balance, usd_cash.cash_balance ]
    assert_equal [ BigDecimal("1400"), BigDecimal("1400") ], [ @sgd_cash.reload.balance, @sgd_cash.cash_balance ]
  end

  test "a buy is a transfer from the cash account, a sell one back to it" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")

    process_all

    buy = transfer_for("b1")
    assert_equal [ usd_cash, BigDecimal("1800") ], [ buy.outflow_transaction.entry.account, buy.outflow_transaction.entry.amount ]
    assert_equal [ @usd_stocks, BigDecimal("-1800") ], [ buy.inflow_transaction.entry.account, buy.inflow_transaction.entry.amount ]
    assert_equal [ "Buy AAPL", Date.new(2026, 10, 10), "USD" ], [ buy.outflow_transaction.entry.name, buy.outflow_transaction.entry.date, buy.outflow_transaction.entry.currency ]

    sell = transfer_for("s1")
    assert_equal [ @usd_stocks, BigDecimal("340") ], [ sell.outflow_transaction.entry.account, sell.outflow_transaction.entry.amount ]
    assert_equal [ usd_cash, BigDecimal("-340") ], [ sell.inflow_transaction.entry.account, sell.inflow_transaction.entry.amount ]

    [ buy, sell ].each do |transfer|
      assert transfer.confirmed?
      assert_equal %w[funds_movement funds_movement], [ transfer.outflow_transaction.reload.kind, transfer.inflow_transaction.reload.kind ]
    end
  end

  test "a second sync on the same day books nothing twice" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all
    counts = -> { [ usd_cash.entries.count, @usd_stocks.entries.count, @sgd_cash.entries.count, Transfer.count ] }
    before = counts.call

    process_all
    # The other processing order links the same legs.
    [ @usd_stocks_row, @usd_cash_row, @primary ].each { |row| process(row) }

    assert_equal before, counts.call
    assert_equal 3, moomoo_transfers.count
  end

  test "a trade transfer the user unlinked stays unlinked" do
    link(@usd_cash_row, "moomoo USD cash")
    process_all
    transfer_for("b1").reject!

    process_all

    assert_nil transfer_for("b1")
    assert transfer_for("s1")
    assert_equal 2, leg("b1", "cash", "stocks").size
  end

  test "a cancelled fill takes both its legs away" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all

    @primary.update!(raw_fills_payload: fills.map { |fill| fill["deal_id"] == "s1" ? fill.merge("status" => "CANCELLED") : fill })
    process_all

    assert_empty leg("s1", "cash", "stocks")
    assert_not usd_cash.entries.where(external_id: "moomoo_fill_1234567890123456_s1").exists?
    assert transfer_for("b1")
  end

  test "until the cash account is set up, its cash isn't imported and the stocks account holds none" do
    process_all

    assert_empty cash_log_names(@usd_stocks)
    assert_equal settlement_ids("stocks"), @usd_stocks.entries.where(entryable_type: "Transaction").order(:external_id).pluck(:external_id)
    assert_equal [ BigDecimal("1800"), BigDecimal("0") ], [ @usd_stocks.reload.balance, @usd_stocks.cash_balance ]
  end

  test "the cash account books the trades' cash even while the stocks account isn't set up" do
    @usd_stocks_row.account_provider.destroy!
    usd_cash = link(@usd_cash_row, "moomoo USD cash")

    process_all
    materialize(usd_cash)

    assert_equal settlement_ids("cash"), usd_cash.entries.where("external_id LIKE 'moomoo_settlement_%'").order(:external_id).pluck(:external_id)
    assert_equal 1, moomoo_transfers.count
    assert usd_cash.balances.where("cash_balance < 0").none?
  end

  test "a per-currency account split before becomes the stocks account and gives up its cash to the new cash account" do
    # Before: one combined account per currency, the USD one with its trades
    # and its cash log.
    @primary.update!(role: "combined", current_balance: 1400)
    @usd_cash_row.destroy!
    @usd_stocks_row.update!(role: "combined", current_balance: 2341, cash_balance: 541)
    process(@primary)
    process(@usd_stocks_row)
    assert_equal [ "Cash Dividend ACME", "Currency Exchange", "Stock Buy Fee" ], cash_log_names(@usd_stocks)
    entry_ids = @usd_stocks.entries.where(entryable_type: "Trade").pluck(:id).sort

    # The sync splits it: SGD has no trades, so its account is its cash
    # account; USD's keeps the trades and gets a cash account to set up.
    @primary.update!(role: "cash")
    @usd_stocks_row.update!(role: "stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    process_all
    assert_empty cash_log_names(@usd_stocks)
    assert_equal BigDecimal("1800"), @usd_stocks.reload.balance

    # Set up: the cash log comes in there and the trades are paid from it.
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all

    assert_equal entry_ids, @usd_stocks.entries.where(entryable_type: "Trade").pluck(:id).sort
    assert_empty cash_log_names(@usd_stocks)
    assert_equal [ "Cash Dividend ACME", "Currency Exchange", "Stock Buy Fee" ], cash_log_names(usd_cash)
    assert transfer_for("b1") && transfer_for("s1")
    assert_equal [ BigDecimal("1800"), BigDecimal("0") ], [ @usd_stocks.reload.balance, @usd_stocks.cash_balance ]
    assert_equal BigDecimal("541"), usd_cash.reload.balance
  end

  test "past balances: the stocks account holds no cash and the cash accounts never go below zero" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all
    [ @sgd_cash, usd_cash, @usd_stocks ].each { |account| materialize(account) }

    first_day = Date.new(2026, 10, 1)
    days = [ first_day - 1, first_day, Date.new(2026, 10, 2), Date.new(2026, 10, 10), Date.new(2026, 10, 12), Date.new(2026, 10, 15), Date.new(2026, 10, 16), Date.current ]
    assert_equal [ 0, 4000, 1400, 1400, 1400, 1400, 1400, 1400 ], cash_on(@sgd_cash, days)
    assert_equal [ 0, 0, 2000, 199, 199, 539, 541, 541 ], cash_on(usd_cash, days)
    assert_equal [ 0 ] * days.size, cash_on(@usd_stocks, days)
    assert_equal BigDecimal("1800"), balance_on(@usd_stocks, Date.current)
    assert_equal 0, balance_on(@usd_stocks, Date.new(2026, 10, 9))

    [ @sgd_cash, usd_cash ].each { |account| assert account.balances.where("cash_balance < -0.01").none?, account.name }
    assert @usd_stocks.balances.where.not(cash_balance: 0).none?

    # All accounts together come to moomoo's total today.
    total = @sgd_cash.reload.balance + (usd_cash.reload.balance + @usd_stocks.reload.balance) * BigDecimal("1.3")
    assert_equal BigDecimal("1400") + BigDecimal("2341") * BigDecimal("1.3"), total

    # A second sync on the same day leaves every day as it was.
    before = [ @sgd_cash, usd_cash, @usd_stocks ].map { |account| account.balances.order(:date).pluck(:date, :cash_balance, :balance) }
    process_all
    [ @sgd_cash, usd_cash, @usd_stocks ].each { |account| materialize(account) }
    assert_equal before, [ @sgd_cash, usd_cash, @usd_stocks ].map { |account| account.balances.order(:date).pluck(:date, :cash_balance, :balance) }
  end

  # 13:00 in New York on Oct 10 is 01:00 in Singapore on Oct 11, after the
  # exchange that paid for the buy at 00:30 Singapore time; the cash log dates
  # the buy's fee on the Singapore day too.
  test "a trade's cash moves on the broker's day, so a trade after midnight there isn't paid before its funding" do
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    late_buy = fill("b1", "BUY", "12", "150", Time.utc(2026, 10, 10, 17))
    moved = { "Currency Exchange" => "10/11/2026 00:30:00", "Stock Buy Execution" => "10/11/2026 01:00:00", "Stock Buy Fee" => "10/11/2026 01:00:00" }
    rows = cash_logs.map do |row|
      time = moved[row["transaction_name"]]
      time ? cash_log(row["transaction_name"], row["cash_change"], row["balance"], time) : row
    end
    @primary.update!(raw_fills_payload: [ late_buy, fills.last ], raw_cash_logs_payload: rows)

    process_all
    [ @sgd_cash, usd_cash, @usd_stocks ].each { |account| materialize(account) }

    assert_equal Date.new(2026, 10, 11), leg("b1", "cash").sole.date
    assert_equal Date.new(2026, 10, 10), leg("b1", "stocks").sole.date
    assert_equal Date.new(2026, 10, 10), @usd_stocks.entries.find_by!(entryable_type: "Trade", external_id: "moomoo_fill_1234567890123456_b1").date
    assert transfer_for("b1").present?

    days = [ Date.new(2026, 10, 9), Date.new(2026, 10, 10), Date.new(2026, 10, 11), Date.new(2026, 10, 12) ]
    assert_equal [ 0, 0, 199, 199 ], cash_on(usd_cash, days)
    assert usd_cash.balances.where("cash_balance < -0.01").none?
    assert @usd_stocks.balances.where.not(cash_balance: 0).none?
  end

  test "an account in one currency stays one account that pays its trades itself" do
    @usd_stocks_row.destroy!
    @usd_cash_row.destroy!
    sgd_fill = fills.first.merge("deal_id" => "sg1", "order_id" => "o-sg1", "code" => "SG.D05", "qty" => "10", "price" => "38")
    @primary.update!(
      role: "combined", current_balance: 4000, cash_balance: 3620,
      raw_positions_payload: [ { "position_side" => "LONG", "code" => "SG.D05", "security_type" => "STOCK", "qty" => "10", "currency" => "SGD", "market_val" => "380.00" } ],
      raw_fills_payload: [ sgd_fill ], raw_orders_payload: { "o-sg1" => { "order_id" => "o-sg1", "currency" => "SGD", "security_type" => "STOCK" } },
      raw_cash_logs_payload: cash_logs.first(1)
    )

    process(@primary)

    assert_equal [ "moomoo_fill_1234567890123456_sg1" ], @sgd_cash.entries.where(entryable_type: "Trade").pluck(:external_id)
    assert_equal [ "Bank Transfer Deposits" ], cash_log_names(@sgd_cash)
    assert_not @sgd_cash.entries.where("external_id LIKE 'moomoo_settlement_%'").exists?
    assert_equal [ BigDecimal("4000"), BigDecimal("3620") ], [ @sgd_cash.reload.balance, @sgd_cash.cash_balance ]
  end

  test "syncs on consecutive days before the cash account is set up leave no cash in the stocks account, before or after it is" do
    # 10-24 and 10-25: only the stocks account is set up; the shares go up
    # to 185 USD on 10-25. 10-26: the cash account is set up.
    process_all
    sync_day("2026-10-25", stocks: 1850)
    process_all
    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("1800") ] ], reconciliations(@usd_stocks)

    sync_day("2026-10-26", stocks: 1850)
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all
    [ @usd_stocks, usd_cash ].each { |account| materialize(account) }

    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("1800") ], [ Date.new(2026, 10, 25), BigDecimal("1850") ] ], reconciliations(@usd_stocks)
    assert @usd_stocks.balances.where.not(cash_balance: 0).none?
    opening = opening_date(@usd_stocks)
    assert_operator opening, :<, Date.new(2026, 10, 10)
    # moomoo's USD total on each sync day: the positions and the USD cash.
    days = [ Date.new(2026, 10, 24), Date.new(2026, 10, 25), Date.new(2026, 10, 26) ]
    assert_equal [ 2341, 2391, 2391 ], days.map { |date| balance_on(@usd_stocks, date) + balance_on(usd_cash, date) }
    assert_equal [ 0 ] * 4, cash_on(@usd_stocks, [ opening, Date.new(2026, 10, 10), Date.new(2026, 10, 16), *days.first(1) ])
    assert_equal [ 0, 0, 2000, 199, 541, 541, 541 ], cash_on(usd_cash, [ opening_date(usd_cash), Date.new(2026, 10, 1), Date.new(2026, 10, 2), Date.new(2026, 10, 10), *days ])
    # Before the sync days, the stocks account is its holdings alone.
    [ opening, Date.new(2026, 10, 9), Date.new(2026, 10, 10), Date.new(2026, 10, 16), Date.new(2026, 10, 23) ].each do |date|
      assert_equal holdings_on(@usd_stocks, date), balance_on(@usd_stocks, date), date.to_s
    end
  end

  test "a combined account that becomes the stocks account on a new day has its balances restated without the cash" do
    combined_days("2026-10-24", "2026-10-25")
    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("2341") ] ], reconciliations(@usd_stocks)

    # 10-26: split, with the cash account not set up yet.
    split_day("2026-10-26")
    process_all
    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("1800") ], [ Date.new(2026, 10, 25), BigDecimal("1800") ] ], reconciliations(@usd_stocks)
    materialize(@usd_stocks)
    assert @usd_stocks.balances.where.not(cash_balance: 0).none?
    assert_equal BigDecimal("1800"), balance_on(@usd_stocks, Date.new(2026, 10, 25))

    # 10-27: the cash account is set up.
    sync_day("2026-10-27", stocks: 1800)
    usd_cash = link(@usd_cash_row, "moomoo USD cash")
    process_all
    process_all
    [ @usd_stocks, usd_cash ].each { |account| materialize(account) }

    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("1800") ], [ Date.new(2026, 10, 25), BigDecimal("1800") ], [ Date.new(2026, 10, 26), BigDecimal("1800") ] ], reconciliations(@usd_stocks)
    assert @usd_stocks.balances.where.not(cash_balance: 0).none?
    assert_equal [ 0 ], cash_on(@usd_stocks, [ opening_date(@usd_stocks) ])
    days = [ Date.new(2026, 10, 24), Date.new(2026, 10, 25), Date.new(2026, 10, 26), Date.new(2026, 10, 27) ]
    assert_equal [ 2341 ] * 4, days.map { |date| balance_on(@usd_stocks, date) + balance_on(usd_cash, date) }
    assert_equal [ 1800 ] * 4, days.map { |date| balance_on(@usd_stocks, date) }
  end

  test "a reconciliation entered or changed by hand is left as it is" do
    combined_days("2026-10-24", "2026-10-25")
    entered = Account::ReconciliationManager.new(@usd_stocks).reconcile_balance(balance: 2300, date: Date.new(2026, 10, 20))
    assert entered.success?
    travel 1.hour
    changed = @usd_stocks.entries.valuations.find_by!(date: Date.new(2026, 10, 24))
    Account::ReconciliationManager.new(@usd_stocks).reconcile_balance(balance: 2350, date: changed.date, existing_valuation_entry: changed)

    split_day("2026-10-26")
    process_all

    assert_equal [
      [ Date.new(2026, 10, 20), BigDecimal("2300") ], [ Date.new(2026, 10, 24), BigDecimal("2350") ], [ Date.new(2026, 10, 25), BigDecimal("1800") ]
    ], reconciliations(@usd_stocks)
  end

  # A notes edit can't be told from an amount edit afterwards, so it leaves
  # the reconciliation as it is too rather than risk overwriting the user's.
  test "a reconciliation whose notes were edited by hand is left as it is" do
    combined_days("2026-10-24", "2026-10-25")
    travel 1.hour
    @usd_stocks.entries.valuations.find_by!(date: Date.new(2026, 10, 24)).update!(notes: "Checked against the statement")

    split_day("2026-10-26")
    process_all

    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("2341") ], [ Date.new(2026, 10, 25), BigDecimal("1800") ] ], reconciliations(@usd_stocks)
  end

  test "a combined account that becomes the cash account loses the balances it recorded with the positions" do
    @usd_stocks_row.destroy!
    @usd_cash_row.destroy!
    @primary.update!(role: "combined", current_balance: BigDecimal("4443.3"), cash_balance: BigDecimal("2103.3"))
    process(@primary)
    sync_day("2026-10-25", stocks: 1800)
    process(@primary)
    assert_equal [ [ Date.new(2026, 10, 24), BigDecimal("4443.3") ] ], reconciliations(@sgd_cash)

    travel_to Time.zone.parse("2026-10-26 12:00:00")
    @primary.update!(role: "cash", current_balance: 1400, cash_balance: 1400, last_seen_at: Time.current, last_positions_sync: Time.current)
    @usd_stocks_row = currency_row("stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    @usd_stocks = link(@usd_stocks_row, "moomoo USD stocks")
    process_all
    materialize(@sgd_cash)

    assert_empty reconciliations(@sgd_cash)
    assert @sgd_cash.holdings.none?
    assert_equal [ 0, 4000, 1400, 1400, 1400, 1400 ], cash_on(@sgd_cash, [ Date.new(2026, 9, 30), Date.new(2026, 10, 1), Date.new(2026, 10, 2), Date.new(2026, 10, 24), Date.new(2026, 10, 25), Date.new(2026, 10, 26) ])
    assert_equal BigDecimal("1400"), balance_on(@sgd_cash, Date.new(2026, 10, 24))
  end

  private

    def process_all
      [ @primary, @usd_cash_row, @usd_stocks_row ].each { |row| process(row) }
    end

    def process(row)
      MoomooAccount::Processor.new(MoomooAccount.find(row.id)).process
    end

    # The next day's snapshot, with the positions at `stocks` USD.
    def sync_day(day, stocks:)
      travel_to Time.zone.parse("#{day} 12:00:00")
      ExchangeRate.find_or_create_by!(from_currency: "USD", to_currency: "SGD", date: Date.current) { |rate| rate.rate = 1.3 }
      price = stocks / 10
      @primary.update!(
        last_seen_at: Time.current, last_positions_sync: Time.current,
        raw_positions_payload: positions.map { |position| position.merge("nominal_price" => price.to_s, "market_val" => stocks.to_s) }
      )
      @usd_stocks_row.update!(current_balance: stocks, cash_balance: 0) if !@usd_stocks_row.destroyed? && @usd_stocks_row.stocks_role?
    end

    # Before the split, on each of `days`: one account per currency, the USD
    # one with its trades, its holdings and its cash log.
    def combined_days(*days)
      @usd_cash_row.destroy!
      @primary.update!(role: "combined")
      @usd_stocks_row.update!(role: "combined", current_balance: 2341, cash_balance: 541)
      days.each do |day|
        sync_day(day, stocks: 1800)
        process(@primary)
        process(@usd_stocks_row)
      end
    end

    # The sync that splits USD: its account keeps the trades and gets a cash
    # account to set up.
    def split_day(day)
      sync_day(day, stocks: 1800)
      @primary.update!(role: "cash")
      @usd_stocks_row.update!(role: "stocks", current_balance: 1800, cash_balance: 0)
      @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    end

    def reconciliations(account)
      account.entries.valuations.joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
        .where(valuations: { kind: "reconciliation" }).order(:date).pluck(:date, :amount)
    end

    # The first day of the account's history.
    def opening_date(account)
      account.balances.minimum(:date)
    end

    def holdings_on(account, date)
      account.holdings.where(date: date, currency: account.currency).sum(:amount).to_d
    end

    # A fresh copy: an account remembers its current anchor.
    def materialize(account)
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances
    end

    def cash_on(account, days)
      cash = account.balances.where(currency: account.currency).pluck(:date, :cash_balance).to_h
      days.map { |date| cash.fetch(date, 0).to_d }
    end

    def balance_on(account, date)
      account.balances.find_by(currency: account.currency, date: date)&.balance.to_d
    end

    def create_account(name, currency)
      @family.accounts.create!(name: name, balance: 0, cash_balance: 0, currency: currency, accountable: Investment.new)
    end

    def currency_row(role, **figures)
      @primary.currency_accounts.create!(
        moomoo_item: @primary.moomoo_item, moomoo_account_id: @primary.moomoo_account_id, currency: "USD", role: role,
        name: "moomoo SG ••3456 (USD #{role})", account_kind: "securities", security_firm: "FUTUSG", **figures
      )
    end

    def link(row, name)
      account = create_account(name, row.currency)
      row.ensure_account_provider!(account)
      account
    end

    def cash_log_names(account)
      account.entries.where("external_id LIKE 'moomoo_cash_log_%'").order(:name).pluck(:name)
    end

    def settlement_ids(leg)
      %w[b1 s1].map { |deal_id| "moomoo_settlement_1234567890123456_#{deal_id}_#{leg}" }
    end

    def leg(deal_id, *legs)
      Entry.where(external_id: legs.map { |leg| "moomoo_settlement_1234567890123456_#{deal_id}_#{leg}" })
    end

    def moomoo_transfers
      transaction_ids = Transaction.joins(:entry).where(entries: { source: "moomoo" }).select(:id)
      Transfer.where(inflow_transaction_id: transaction_ids)
    end

    def transfer_for(deal_id)
      transaction_ids = Transaction.joins(:entry).merge(leg(deal_id, "cash", "stocks")).select(:id)
      Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids)).first
    end

    def positions
      [ { "position_side" => "LONG", "code" => "US.AAPL", "stock_name" => "Apple", "security_type" => "STOCK", "qty" => "10", "currency" => "USD",
          "nominal_price" => "180.000", "cost_price_valid" => false, "market_val" => "1800.00" } ]
    end

    def fills
      [ fill("b1", "BUY", "12", "150", Time.utc(2026, 10, 10, 15)), fill("s1", "SELL", "2", "170", Time.utc(2026, 10, 15, 15)) ]
    end

    def fill(deal_id, side, qty, price, time)
      micros = Provider::Moomoo.to_micros(time)
      { "deal_id" => deal_id, "order_id" => "o-#{deal_id}", "trd_side" => side, "code" => "US.AAPL", "stock_name" => "Apple",
        "qty" => qty, "price" => price, "create_time" => micros, "updated_time" => micros, "status" => "OK" }
    end

    def orders
      %w[b1 s1].to_h { |deal_id| [ "o-#{deal_id}", { "order_id" => "o-#{deal_id}", "currency" => "USD", "security_type" => "STOCK" } ] }
    end

    def cash_logs
      [
        cash_log("Bank Transfer Deposits", "+4,000.00", "Balance: 4,000.00 SGD", "10/01/2026 09:00:00"),
        cash_log("Currency Exchange", "-2,600.00", "Balance: 1,400.00 SGD", "10/02/2026 10:00:00"),
        cash_log("Currency Exchange", "+2,000.00", "Balance: 2,000.00 USD", "10/02/2026 10:00:00"),
        cash_log("Stock Buy Execution", "-1,800.00", "Balance: 200.00 USD", "10/10/2026 23:00:00"),
        cash_log("Stock Buy Fee", "-1.00", "Balance: 199.00 USD", "10/10/2026 23:00:00"),
        cash_log("Stock Sell Execution", "+340.00", "Balance: 539.00 USD", "10/15/2026 23:00:00"),
        cash_log("Cash Dividend", "+2.00", "Balance: 541.00 USD", "10/16/2026 10:00:00", symbol: "ACME")
      ]
    end

    def cash_log(name, change, balance, time, symbol: "")
      fields = { "transaction_name" => name, "created_time" => time, "cash_change" => change, "balance" => balance, "symbol" => symbol, "stock_name" => "" }
      fields.merge("digest" => Digest::SHA256.hexdigest(fields.values.join("|"))[0, 32])
    end
end
