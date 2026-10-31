require "test_helper"

class Account::CashAnchorTest < ActiveSupport::TestCase
  # A manual account worth 1,100: 100 in cash and 10 AAPL at 100.
  setup do
    @account = accounts(:crypto)
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    @aapl = securities(:aapl)
    @other = securities(:msft)
    (4.days.ago.to_date..Date.current).each do |date|
      @aapl.prices.find_or_initialize_by(date: date).update!(price: 100, currency: "USD")
    end
    @other.prices.find_or_initialize_by(date: Date.current).update!(price: 100, currency: "USD")
    @account.entries.create!(date: 3.days.ago.to_date, amount: 1100, currency: "USD", name: "Opening",
      entryable: Valuation.new(kind: "opening_anchor"))
    @account.entries.create!(date: 2.days.ago.to_date, amount: 1000, currency: "USD", name: "Buy AAPL",
      entryable: Trade.new(security: @aapl, qty: 10, price: 100, currency: "USD", investment_activity_label: "Buy"))
    materialize
  end

  test "the anchor keeps the account's cash and opts it into forward accounting" do
    anchor = @account.create_cash_anchor!
    assert anchor.entryable.cash_anchor?
    assert_equal 100, anchor.amount
    assert_equal Date.current, @account.accounting_start_date
    materialize
    assert_equal 100, @account.reload.cash_balance
    assert_equal 1100, @account.balance
  end

  test "foreign cash movements use the standard dated exchange rate" do
    @account.create_cash_anchor!
    ExchangeRate.find_or_initialize_by(from_currency: "EUR", to_currency: "USD", date: Date.current).update!(rate: "1.2")
    cash_entry(amount: 10, currency: "EUR")
    materialize
    assert_equal 88, @account.reload.cash_balance
    assert_equal 1088, @account.balance
  end

  test "manual trade exchange rates are retained in cash and basis" do
    @account.create_cash_anchor!
    trade = Trade.new(security: @other, qty: 2, price: 10, currency: "EUR", exchange_rate: 2)
    @account.entries.create!(date: Date.current, amount: 20, currency: "EUR", name: "Buy", entryable: trade)
    materialize
    assert_equal 60, @account.reload.cash_balance
    assert_equal 20, @account.current_holdings.find_by!(security: @other).cost_basis
  end

  test "split parents are excluded from cash and flows" do
    @account.create_cash_anchor!
    cash_entry(amount: 100).split!([ { name: "First", amount: 40 }, { name: "Second", amount: 60 } ])
    materialize
    assert_equal 0, @account.reload.cash_balance
    assert_equal 100, @account.balances.find_by!(date: Date.current).cash_outflows
  end

  test "a later absolute valuation on the anchor day overrides the cash anchor" do
    @account.create_cash_anchor!
    travel 1.second do
      @account.entries.create!(date: Date.current, amount: 3000, currency: "USD", name: "Total valuation", entryable: Valuation.new)
      materialize
      assert_equal 3000, @account.reload.balance
      assert_equal 2000, @account.cash_balance
    end
  end

  test "an earlier valuation on the anchor day does not replace the anchored cash" do
    @account.entries.create!(date: Date.current, amount: 1500, currency: "USD", name: "Old total", entryable: Valuation.new)
    travel 1.second do
      @account.create_cash_anchor!
      @aapl.prices.find_by!(date: Date.current).update!(price: 110)
      materialize
      assert_equal 500, @account.reload.cash_balance
      assert_equal 1600, @account.balance
    end
  end

  test "notes on a superseded valuation do not restore its old total" do
    old = @account.entries.create!(date: Date.current, amount: 1500, currency: "USD", name: "Old total", entryable: Valuation.new)
    @account.create_cash_anchor!
    old.update!(notes: "Keep this historical note")
    @aapl.prices.find_by!(date: Date.current).update!(price: 110)
    materialize
    assert_equal 1600, @account.reload.balance
  end

  test "an amount edit restores a superseded valuation" do
    old = @account.entries.create!(date: Date.current, amount: 1500, currency: "USD", name: "Old total", entryable: Valuation.new)
    @account.create_cash_anchor!
    old.reload.update!(amount: 3000)
    materialize
    assert_equal 3000, @account.reload.balance
  end

  test "an unchanged reconciliation restores a superseded valuation" do
    old = @account.entries.create!(date: Date.current, amount: 1500, currency: "USD", name: "Old total", entryable: Valuation.new)
    @account.create_cash_anchor!
    result = @account.update_reconciliation(old.reload, balance: 1500, date: Date.current)
    assert result.success?, result.error_message
    @aapl.prices.find_by!(date: Date.current).update!(price: 110)
    materialize
    assert_equal 1500, @account.reload.balance
  end

  test "the public reconciliation workflow keeps a total valuation distinct from the cash anchor" do
    @account.create_cash_anchor!
    travel 1.second do
      result = @account.create_reconciliation(balance: 3000, date: Date.current)
      assert result.success?, result.error_message
      materialize
      assert_equal 3000, @account.reload.balance
      assert_equal 2000, @account.cash_balance
      assert_equal 1, @account.valuations.cash_anchor.count
      assert_equal 1, @account.valuations.reconciliation.count
    end
  end

  test "editing the cash anchor establishes a new absolute cash value" do
    entry = cash_entry(amount: 10, date: Date.current.prev_day)
    @account.create_cash_anchor!
    entry.update!(amount: 20)
    anchor = @account.entries.valuations.find_by!(entryable_id: Valuation.cash_anchor.select(:id))
    result = @account.update_reconciliation(anchor, balance: 200, date: Date.current)
    assert result.success?, result.error_message
    materialize
    assert_equal 200, @account.reload.cash_balance
  end

  test "editing an earlier cash movement applies its delta through the anchor" do
    entry = cash_entry(amount: 10, date: Date.current.prev_day)
    # Not synced yet, so only the ledger, not cash_balance, has it.
    assert_equal 90, @account.create_cash_anchor!.amount
    entry.update!(amount: 20)
    materialize(window_start_date: entry.date)
    assert_equal 80, @account.reload.cash_balance
  end

  test "a movement dated after the anchor day is counted once" do
    cash_entry(amount: 10, date: Date.current.next_day)
    materialize
    @account.create_cash_anchor!
    travel 1.day do
      materialize
      assert_equal 90, @account.reload.cash_balance
    end
  end

  test "backdated new cash movements are included once" do
    @account.create_cash_anchor!
    cash_entry(amount: 15, date: 3.days.ago.to_date)
    2.times { materialize(window_start_date: 3.days.ago.to_date) }
    assert_equal 85, @account.reload.cash_balance
  end

  test "deleting a past cash movement rebuilds from its date" do
    @account.create_cash_anchor!
    entry = cash_entry(amount: 10, date: 3.days.ago.to_date)
    materialize(window_start_date: entry.date)
    assert_equal 90, @account.reload.cash_balance

    entry.destroy!
    Account.any_instance.expects(:sync_later).with(window_start_date: entry.date)
    entry.sync_account_later
    materialize(window_start_date: entry.date)
    assert_equal 100, @account.reload.cash_balance
  end

  test "a sync without a start date still applies a backdated cash movement" do
    travel_to(1.day.ago) { @account.create_cash_anchor! }
    materialize
    cash_entry(amount: 10, date: Date.current.prev_day)
    materialize
    assert_equal 90, @account.reload.cash_balance
  end

  test "deleting the last trade of a security removes its position" do
    @account.create_cash_anchor!
    trade = @account.entries.create!(date: Date.current, amount: 200, currency: "USD", name: "Buy MSFT",
      entryable: Trade.new(security: @other, qty: 2, price: 100, currency: "USD", investment_activity_label: "Buy"))
    materialize
    assert_equal 2, @account.current_holdings.find_by!(security: @other).qty

    trade.destroy!
    materialize(window_start_date: trade.date)
    assert_nil @account.current_holdings.find_by(security: @other)
    assert_equal 1100, @account.reload.balance
  end

  test "a split before the window still scales the position" do
    @account.create_cash_anchor!
    Security::Split.create!(security: @aapl, ex_date: Date.current.prev_day, numerator: 2, denominator: 1, source: "manual")
    @aapl.prices.where(date: Date.current.prev_day..).update_all(price: 50)
    materialize(window_start_date: Date.current)
    assert_equal 20, @account.current_holdings.find_by!(security: @aapl).qty
    assert_equal 1100, @account.reload.balance
  end

  test "new manual assets are not copied backward and existing rows are repriced" do
    @account.create_cash_anchor!
    anchored = Date.current
    travel 1.day do
      @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")
      @other.prices.create!(date: Date.current, price: 120, currency: "USD")
      materialize
      assert_equal 240, @account.current_holdings.find_by!(security: @other).amount
      assert_empty @account.holdings.where(security: @other, date: ..anchored).where.not(qty: 0)
    end
  end

  test "untraded foreign holdings are valued in the account currency" do
    ExchangeRate.find_or_initialize_by(from_currency: "EUR", to_currency: "USD", date: Date.current).update!(rate: 2)
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 30, amount: 60, currency: "EUR")
    @other.prices.find_by!(date: Date.current).update!(price: 30, currency: "EUR")
    @account.create_cash_anchor!
    materialize
    assert_equal 1220, @account.reload.balance
    assert_equal 60, @account.current_holdings.find_by!(security: @other).amount
    assert_equal "EUR", @account.current_holdings.find_by!(security: @other).currency
    assert_includes Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation.map(&:security_id), @other.id
  end

  test "manual basis and locks survive carrying an untraded asset" do
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", cost_basis: 50, cost_basis_source: "manual", cost_basis_locked: true, security_locked: true)
    @account.create_cash_anchor!
    travel 1.day do
      materialize
      holding = @account.current_holdings.find_by!(security: @other)
      assert_equal 50, holding.cost_basis
      assert holding.cost_basis_locked?
      assert holding.security_locked?
    end
  end

  test "deleting an untraded position removes its series and rebuilds from its first day" do
    @account.holdings.create!(security: @other, date: Date.current.prev_day, qty: 2, price: 100, amount: 200, currency: "USD")
    @account.create_cash_anchor!
    Account.any_instance.expects(:sync_later).with(window_start_date: Date.current.prev_day)
    @account.current_holdings.find_by!(security: @other).destroy_holding_and_entries!
    materialize
    assert_empty @account.holdings.where(security: @other)
  end

  test "a missing FX rate keeps the last valuation instead of failing the sync" do
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    @account.update!(currency: "EUR", balance: 100, cash_balance: 100)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 90, amount: 180, currency: "EUR")
    @account.create_cash_anchor!
    materialize
    valued = @account.reload.balance

    ExchangeRate.where(from_currency: "USD", to_currency: "EUR").delete_all
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    assert_nothing_raised do
      Account::Syncer.new(@account.reload).perform_sync(@account.syncs.create!)
    end
    assert_operator valued, :>, 100
    assert_equal valued, @account.reload.balance
  end

  test "a year of history is kept outside each materialization window" do
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    start_date = Date.current - 365
    @account.entries.create!(date: start_date - 1, amount: 100, currency: "USD", name: "Opening",
      entryable: Valuation.new(kind: "opening_anchor"))
    travel_to(start_date.noon) { @account.create_cash_anchor! }
    # Activity today, so the balance series runs up to today.
    cash_entry(amount: 1)
    materialize(window_start_date: start_date)
    assert_equal 366, @account.balances.count
    assert_equal 99, @account.reload.balance

    history = @account.balances.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)
    materialize(window_start_date: Date.current)
    assert_equal history, @account.balances.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)

    edit_date = 30.days.ago.to_date
    earlier = @account.balances.where(date: ...edit_date).order(:date).pluck(:id, :updated_at)
    cash_entry(amount: 5, date: edit_date)
    materialize(window_start_date: edit_date)
    assert_equal earlier, @account.balances.where(date: ...edit_date).order(:date).pluck(:id, :updated_at)
    assert_equal 94, @account.reload.cash_balance
  end

  test "a pending account sync cannot be borrowed by a different parent" do
    @account.create_cash_anchor!
    first = @account.family.syncs.create!
    second = @account.family.syncs.create!
    one = @account.sync_later(parent_sync: first)
    two = @account.sync_later(parent_sync: second)
    refute_equal one.id, two.id
    assert_equal first.id, one.parent_id
    assert_equal second.id, two.parent_id
    assert_equal two.id, @account.sync_later(parent_sync: second).id
  end

  test "an in-flight account sync always gets a follow-up for later data" do
    @account.create_cash_anchor!
    first = @account.syncs.create!(status: "syncing")
    next_sync = @account.sync_later
    refute_equal first.id, next_sync.id
    assert next_sync.pending?
  end

  private
    def cash_entry(amount:, currency: "USD", date: Date.current)
      @account.entries.create!(date: date, amount: amount, currency: currency, name: "Cash movement", entryable: Transaction.new)
    end

    def materialize(**options)
      Balance::Materializer.new(@account, strategy: :forward, **options).materialize_balances
    end
end
