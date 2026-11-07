require "test_helper"

# The cash accounts of a moomoo account split by currency are cash
# (Depository) accounts, their stocks accounts investment accounts, and the
# transfers that pay for trades stay plain funds movements.
class MoomooAccount::CashDepositoryTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @family = families(:dylan_family)
    @item = moomoo_items(:connected_item)
    @primary = moomoo_accounts(:main_account)
    # 4,000 SGD in, 2,600 SGD exchanged for 2,000 USD, 12 shares bought for
    # 1,800 USD with a 1 USD fee, 2 sold for 340 USD, a 2 USD dividend.
    @primary.update!(
      role: "cash", current_balance: 1400, cash_balance: 1400, last_seen_at: Time.current, last_positions_sync: Time.current,
      raw_positions_payload: positions, raw_fills_payload: fills, raw_orders_payload: orders, raw_cash_logs_payload: cash_logs
    )
    @usd_stocks_row = currency_row("stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)

    Security::Resolver.stubs(:new).returns(stub(resolve: securities(:aapl)))
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: Date.current, rate: 1.3)
  end

  test "the setup creates cash accounts as Depository accounts and the others as investment accounts" do
    sgd_cash, usd_cash, usd_stocks = set_up_all

    [ sgd_cash, usd_cash ].each do |account|
      assert_equal [ "Depository", "checking" ], [ account.accountable_type, account.subtype ]
    end
    assert_equal [ "Investment", "brokerage" ], [ usd_stocks.accountable_type, usd_stocks.subtype ]
    assert_equal [ "SGD", "USD", "USD" ], [ sgd_cash, usd_cash, usd_stocks ].map(&:currency)

    @primary.update!(role: "combined")
    assert_equal "Investment", Account.create_from_moomoo_account(@primary).accountable_type
  end

  test "the trades are paid by funds movements on both legs, kept on every later sync" do
    sgd_cash, usd_cash, usd_stocks = set_up_all
    process_all

    buy = transfer_for("b1")
    assert_equal [ usd_cash, usd_stocks ], [ buy.from_account, buy.to_account ]
    assert_trade_payments_are_funds_movements
    # The buy's cash leg would be an investment contribution by default; it
    # is kept a funds movement the way a user switches it.
    assert buy.outflow_transaction.locked?(:kind)
    assert_equal false, buy.investment_contribution_choice

    # A repeat sync, Sure's own kind repair, auto-matching and a sync on the
    # next day change none of it.
    process_all
    Transfer::InvestmentKindReconciler.new.run
    @family.auto_match_transfers!
    sync_day("2026-10-25")
    process_all
    Transfer::InvestmentKindReconciler.new.run

    assert_trade_payments_are_funds_movements
    assert_equal 3, moomoo_transfers.count

    deposit = cash_log_entry(sgd_cash, "Bank Transfer Deposits")
    assert_equal [ nil, "funds_movement", nil ], [ deposit.entryable.investment_activity_label, deposit.entryable.kind, deposit.entryable.category_id ]
    [ sgd_cash, usd_cash, usd_stocks ].each { |account| assert_equal "funds_movement", account.transactions.where.not(kind: "standard").distinct.pluck(:kind).sole }
  end

  test "a deposit from the user's bank account is a funds movement on both sides" do
    sgd_cash, = set_up_all
    process_all
    bank = @family.accounts.create!(name: "Bank", balance: 10_000, currency: "SGD", accountable: Depository.new(subtype: "checking"))
    bank.entries.create!(name: "To moomoo", date: Date.new(2026, 10, 1), amount: 4000, currency: "SGD", entryable: Transaction.new)

    @family.auto_match_transfers!
    deposit = cash_log_entry(sgd_cash, "Bank Transfer Deposits").entryable
    transfer = deposit.reload.transfer
    assert transfer.pending?
    transfer.confirm!
    process_all

    assert_equal [ bank, sgd_cash ], [ transfer.reload.from_account, transfer.to_account ]
    assert_equal %w[funds_movement funds_movement], [ transfer.outflow_transaction.reload.kind, transfer.inflow_transaction.reload.kind ]
    assert_not transfer.investment_contribution_switchable?
  end

  test "the first sync after the update makes the existing cash accounts Depository accounts and keeps their history" do
    # Before: the cash accounts were set up as investment accounts, as the
    # setup did then.
    sgd_cash, usd_cash, usd_stocks = with_investment_cash_accounts do
      accounts = set_up_all
      process_all
      sync_day("2026-10-25")
      process_all
      accounts
    end
    assert_equal %w[Investment Investment], [ sgd_cash, usd_cash ].map { |account| account.reload.accountable_type }
    deposit = cash_log_entry(sgd_cash, "Bank Transfer Deposits").entryable
    assert_equal [ "Contribution", "investment_contribution", @family.investment_contributions_category ], [ deposit.investment_activity_label, deposit.kind, deposit.category ]
    accounts = [ sgd_cash, usd_cash, usd_stocks ]
    accounts.each { |account| materialize(account) }
    before = history(accounts)

    # The next day's sync, the first after the update.
    sync_day("2026-10-26")
    process_all
    accounts.each { |account| materialize(account) }

    assert_equal [ "Depository", "checking" ], [ sgd_cash.reload.accountable_type, sgd_cash.subtype ]
    assert_equal [ "Depository", "checking" ], [ usd_cash.reload.accountable_type, usd_cash.subtype ]
    assert_equal "Investment", usd_stocks.reload.accountable_type
    assert_equal [ sgd_cash, usd_cash, usd_stocks ], [ @primary, @usd_cash_row, @usd_stocks_row ].map { |row| MoomooAccount.find(row.id).current_account }
    assert_not Investment.exists?(id: before[:accountables].first(2))

    after = history(accounts)
    # Every entry is where it was; the new day adds only its current balance.
    assert_equal before[:entries], after[:entries].map { |entries| entries.reject { |entry| entry[3] == Date.current } }
    assert_equal [ [ "Valuation" ] ] * 3, after[:entries].map { |entries| entries.select { |entry| entry[3] == Date.current }.map(&:second) }
    assert_equal before[:transfers], after[:transfers]
    # Each day's balance is as it was, and today's is yesterday's: nothing
    # moved since.
    accounts.each_with_index do |account, index|
      assert_equal before[:balances][index], after[:balances][index].reject { |date, *| date == Date.current }, account.name
      assert_equal before[:balances][index].last.drop(1), after[:balances][index].last.drop(1), account.name
    end
    assert_trade_payments_are_funds_movements
    deposit.reload
    assert_equal [ nil, "funds_movement", nil ], [ deposit.investment_activity_label, deposit.kind, deposit.category ]

    # Together the accounts still come to moomoo's total.
    total = sgd_cash.balance + (usd_cash.balance + usd_stocks.balance) * BigDecimal("1.3")
    assert_equal BigDecimal("1400") + BigDecimal("2341") * BigDecimal("1.3"), total

    # A repeat sync converts nothing again and changes nothing.
    assert_no_difference -> { DebugLogEntry.where("message LIKE 'MoomooAccount::CashAccountConversion%'").count } do
      process_all
      accounts.each { |account| materialize(account) }
    end
    assert_equal after, history(accounts)
  end

  test "an investment account the user made and linked to a cash row stays an investment account" do
    @manual = @family.accounts.create!(name: "My moomoo cash", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @manual.update_column(:created_at, 1.day.ago)
    @usd_cash_row.ensure_account_provider!(@manual)
    set_up(@primary)
    set_up(@usd_stocks_row)

    process_all
    @item.process_accounts

    assert_equal "Investment", @manual.reload.accountable_type
    assert_trade_payments_are_funds_movements
    # The exchange from the SGD cash account into the manual investment
    # account only converts cash, so it is no investment contribution.
    assert_exchange_is_funds_movement(from: "Depository", to: "Investment")
  end

  test "a currency exchange into a manual investment account stays a funds movement when the other cash account is converted" do
    @manual = @family.accounts.create!(name: "My moomoo cash", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @manual.update_column(:created_at, 1.day.ago)
    sgd_cash = with_investment_cash_accounts do
      @usd_cash_row.ensure_account_provider!(@manual)
      set_up(@usd_stocks_row)
      account = set_up(@primary)
      process_all
      account
    end
    assert_equal "Investment", sgd_cash.reload.accountable_type
    assert_exchange_is_funds_movement(from: "Investment", to: "Investment")

    sync_day("2026-10-25")
    process_all
    assert_equal "Depository", sgd_cash.reload.accountable_type
    assert_equal "Investment", @manual.reload.accountable_type
    assert_exchange_is_funds_movement(from: "Depository", to: "Investment")

    sync_day("2026-10-26")
    process_all
    Transfer::InvestmentKindReconciler.new.run
    @family.auto_match_transfers!
    process_all
    assert_exchange_is_funds_movement(from: "Depository", to: "Investment")
    assert_trade_payments_are_funds_movements
  end

  test "a deposit the user edited loses the contribution kind, label and category on conversion but keeps the edit" do
    sgd_cash, = with_investment_cash_accounts do
      accounts = set_up_all
      process_all
      accounts
    end
    entry = cash_log_entry(sgd_cash, "Bank Transfer Deposits")
    entry.update!(notes: "From my bank")
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    sync_day("2026-10-25")
    process_all
    process_all

    assert_equal "Depository", sgd_cash.reload.accountable_type
    entry.reload
    assert_equal [ nil, "funds_movement", nil, "From my bank" ], [ entry.entryable.investment_activity_label, entry.entryable.kind, entry.entryable.category, entry.notes ]
    assert entry.user_modified?
  end

  test "a deposit whose kind and category the user chose keeps them on conversion" do
    sgd_cash, = with_investment_cash_accounts do
      accounts = set_up_all
      process_all
      accounts
    end
    entry = cash_log_entry(sgd_cash, "Bank Transfer Deposits")
    category = @family.categories.create!(name: "Savings top-up")
    entry.entryable.update!(category: category, kind: "standard")
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    sync_day("2026-10-25")
    process_all

    assert_equal "Depository", sgd_cash.reload.accountable_type
    transaction = entry.reload.entryable
    assert_equal [ nil, "standard", category ], [ transaction.investment_activity_label, transaction.kind, transaction.category ]
  end

  test "a former combined account still holding its stocks account's trades is converted once they are taken" do
    @usd_stocks_row.destroy!
    @usd_cash_row.destroy!
    @primary.update!(role: "combined", current_balance: BigDecimal("4443.3"), cash_balance: BigDecimal("2103.3"))
    sgd = set_up(@primary)
    process(@primary)
    assert_equal "Investment", sgd.reload.accountable_type
    assert sgd.entries.where(entryable_type: "Trade").exists?

    # The split: SGD has no trades, so its account becomes the SGD cash
    # account; it gives the USD trades to the USD stocks account.
    sync_day("2026-10-25")
    @primary.update!(role: "cash", current_balance: 1400, cash_balance: 1400)
    @usd_stocks_row = currency_row("stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    usd_stocks = set_up(@usd_stocks_row)
    process(@primary)
    assert_equal "Investment", sgd.reload.accountable_type

    @item.process_accounts

    assert_equal "Depository", sgd.reload.accountable_type
    assert_not sgd.entries.where(entryable_type: "Trade").exists?
    assert sgd.holdings.none?
    assert usd_stocks.entries.where(entryable_type: "Trade").exists?
  end

  test "a former combined account keeping a trade the user edited stays an investment account and logs why" do
    @usd_stocks_row.destroy!
    @usd_cash_row.destroy!
    @primary.update!(role: "combined", current_balance: BigDecimal("4443.3"), cash_balance: BigDecimal("2103.3"))
    sgd = set_up(@primary)
    process(@primary)
    edited = sgd.entries.where(entryable_type: "Trade").order(:date).first
    edited.update!(notes: "Checked against the contract note")
    edited.lock_saved_attributes!
    edited.mark_user_modified!

    sync_day("2026-10-25")
    @primary.update!(role: "cash", current_balance: 1400, cash_balance: 1400)
    @usd_stocks_row = currency_row("stocks", current_balance: 1800, cash_balance: 0)
    @usd_cash_row = currency_row("cash", current_balance: 541, cash_balance: 541)
    # The USD stocks account is not set up yet: the trades it would take are
    # dropped, except the one the user edited.
    @item.process_accounts
    @item.process_accounts

    assert_equal "Investment", sgd.reload.accountable_type
    assert_equal edited, sgd.entries.where(entryable_type: "Trade").sole
    waiting = DebugLogEntry.where(level: "info").where("message LIKE ?", "MoomooAccount::CashAccountConversion - the SGD cash account stays an investment account%")
    assert waiting.exists?
    # The first sync logs it before the trades are dropped, the second after.
    assert_equal [ 1, 2 ], waiting.map { |entry| entry.metadata["trades"] }.uniq.sort

    # Once it is, it takes the edited trade and the cash account converts.
    usd_stocks = set_up(@usd_stocks_row)
    @item.process_accounts
    @item.process_accounts

    assert_equal "Depository", sgd.reload.accountable_type
    assert_equal edited, usd_stocks.entries.find_by(external_id: edited.external_id)
  end

  private

    def set_up_all
      [ @primary, @usd_cash_row, @usd_stocks_row ].map { |row| set_up(row) }
    end

    def set_up(row)
      account = Account.create_from_moomoo_account(row)
      row.ensure_account_provider!(account)
      account
    end

    # The setup as it was before cash accounts were Depository accounts.
    def with_investment_cash_accounts
      MoomooAccount.any_instance.stubs(:sure_accountable).returns(MoomooAccount::INVESTMENT_ACCOUNTABLE)
      MoomooAccount::CashAccountConversion.any_instance.stubs(:convert).returns(false)
      yield
    ensure
      MoomooAccount.any_instance.unstub(:sure_accountable)
      MoomooAccount::CashAccountConversion.any_instance.unstub(:convert)
    end

    def process_all
      [ @primary, @usd_cash_row, @usd_stocks_row ].each { |row| process(row) }
    end

    def process(row)
      MoomooAccount::Processor.new(MoomooAccount.find(row.id)).process
    end

    # The next day's snapshot, unchanged.
    def sync_day(day)
      travel_to Time.zone.parse("#{day} 12:00:00")
      ExchangeRate.find_or_create_by!(from_currency: "USD", to_currency: "SGD", date: Date.current) { |rate| rate.rate = 1.3 }
      @primary.update!(last_seen_at: Time.current, last_positions_sync: Time.current)
    end

    def materialize(account)
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances
    end

    def history(accounts)
      ids = Transaction.joins(:entry).where(entries: { account_id: accounts.map(&:id) }).select(:id)
      {
        accountables: accounts.map { |account| account.reload.accountable_id },
        entries: accounts.map { |account| account.entries.order(:id).pluck(:id, :entryable_type, :entryable_id, :date, :amount, :currency) },
        transfers: Transfer.where(inflow_transaction_id: ids).or(Transfer.where(outflow_transaction_id: ids)).order(:id).pluck(:id, :inflow_transaction_id, :outflow_transaction_id, :status),
        balances: accounts.map { |account| account.balances.where(currency: account.currency).order(:date).pluck(:date, :balance, :cash_balance) }
      }
    end

    def assert_trade_payments_are_funds_movements
      %w[b1 s1].each do |deal_id|
        transfer = transfer_for(deal_id)
        assert transfer&.confirmed?, deal_id
        assert_equal %w[funds_movement funds_movement], [ transfer.outflow_transaction.reload.kind, transfer.inflow_transaction.reload.kind ], deal_id
        assert_not transfer.investment_contribution?, deal_id
      end
    end

    def assert_exchange_is_funds_movement(from:, to:)
      outflow = Entry.where("external_id LIKE 'moomoo_cash_log_%'").where(name: "Currency Exchange").find_by!("amount > 0").entryable
      transfer = outflow.reload.transfer
      assert transfer&.confirmed?
      assert_equal [ from, to ], [ transfer.from_account.accountable_type, transfer.to_account.accountable_type ]
      assert_equal %w[funds_movement funds_movement], [ transfer.outflow_transaction.reload.kind, transfer.inflow_transaction.reload.kind ]
      assert_nil transfer.outflow_transaction.category
      assert_not transfer.investment_contribution?
    end

    def cash_log_entry(account, name)
      account.entries.where("external_id LIKE 'moomoo_cash_log_%'").find_by!(name: name)
    end

    def currency_row(role, **figures)
      @primary.currency_accounts.create!(
        moomoo_item: @item, moomoo_account_id: @primary.moomoo_account_id, currency: "USD", role: role,
        name: "moomoo SG ••3456 (USD #{role})", account_kind: "securities", security_firm: "FUTUSG", **figures
      )
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
