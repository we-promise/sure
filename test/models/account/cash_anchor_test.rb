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

  test "the cash value and ledger baseline use the same entries" do
    debit = cash_entry(amount: 10, date: Date.yesterday)
    calculator = Balance::ForwardCalculator.new(@account)
    calculate = calculator.method(:calculate)
    calculator.define_singleton_method(:calculate) do |**options|
      balances = calculate.call(**options)
      debit.update!(amount: 20)
      balances
    end
    Balance::ForwardCalculator.expects(:new).with(@account).returns(calculator)

    anchor = @account.create_cash_anchor!

    assert_equal 90, anchor.amount
    assert_equal 1010, anchor.entryable.cash_entry_total
  end

  test "an entry moved to the anchor date is replayed before capturing cash" do
    @account.holdings.delete_all
    debit = cash_entry(amount: 10, date: Date.yesterday)
    cache = Balance::SyncCache.new(@account)
    converted_entries = cache.method(:converted_entries)
    cache.define_singleton_method(:converted_entries) do
      debit.update!(date: Date.current) unless debit.date == Date.current
      converted_entries.call
    end
    Balance::SyncCache.stubs(:new).with(@account, start_date: nil).returns(cache)

    anchor = @account.create_cash_anchor!

    assert_equal Date.current, debit.reload.date
    assert_equal 90, anchor.amount
    assert_equal 1010, anchor.entryable.cash_entry_total
  end

  test "without an opening valuation the anchor uses only convertible movements" do
    @account.entries.destroy_all
    @account.holdings.delete_all
    cash_entry(amount: -10, date: Date.yesterday)
    cash_entry(amount: -500, currency: "JPY", date: Date.current)
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    anchor = @account.create_cash_anchor!

    assert_equal 10, anchor.amount
    assert_equal(-10, anchor.entryable.cash_entry_total)
  end

  test "a backdated credit card charge increases the anchored debt" do
    card = accounts(:credit_card)
    card.entries.destroy_all
    card.balances.destroy_all
    card.entries.create!(date: Date.yesterday, name: "Opening", amount: 100, currency: "USD",
      entryable: Valuation.new(kind: :opening_anchor))
    card.create_cash_anchor!

    card.entries.create!(date: Date.yesterday, name: "Charge", amount: 10, currency: "USD", entryable: Transaction.new)
    Balance::Materializer.new(card, strategy: :forward, window_start_date: Date.yesterday).materialize_balances

    assert_equal 110, card.reload.cash_balance
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

  test "journal replay preserves a manual observation on the trade date" do
    @account.create_cash_anchor!
    today = Date.current
    snapshot = @account.holdings.create!(security: @other, date: today, qty: 3, price: 100, amount: 300, currency: "USD")
    trade = @account.entries.create!(date: today, amount: 200, currency: "USD", name: "Buy MSFT",
      entryable: Trade.new(security: @other, qty: 2, price: 100, currency: "USD", investment_activity_label: "Buy"))
    materialize

    assert_equal 3, snapshot.reload.qty
    assert_equal 3, @account.current_holdings.find_by!(security: @other).qty

    travel 1.day do
      materialize
      assert_equal 2, @account.current_holdings.find_by!(security: @other).qty
      trade.destroy!
      trade.sync_account_later
      materialize
      assert_equal 3, @account.current_holdings.find_by!(security: @other).qty
    end
  end

  test "a provider holding does not delete an independent observation on the same day" do
    @account.create_cash_anchor!
    item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: @account, provider: item.coinstats_accounts.create!(name: "Wallet", currency: "USD"))
    provider_snapshot = @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", account_provider_id: provider.id)
    manual_snapshot = @account.holdings.create!(security: @other, date: Date.current, qty: 3, price: 100, amount: 300, currency: "EUR")
    calculated = @account.holdings.create!(security: @other, date: Date.current, qty: 3, price: 100, amount: 300,
      currency: "GBP", materialized: true, cost_basis: 45, cost_basis_source: "manual", cost_basis_locked: true)
    materialize

    assert Holding.exists?(manual_snapshot.id)
    assert_equal provider_snapshot, @account.current_holdings.find_by!(security: @other)
    assert calculated.reload.superseded?
    assert_equal 45, calculated.cost_basis
    assert calculated.cost_basis_locked?
  end

  test "a replay selects the newly carried currency while retaining the old locked basis" do
    @account.create_cash_anchor!
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")

    travel 2.days do
      materialize
      old_copy = @account.current_holdings.find_by!(security: @other)
      old_copy.set_manual_cost_basis!(45)
      observed_on = Date.current.prev_day
      new_snapshot = @account.holdings.create!(security: @other, date: observed_on, qty: 3, price: 100, amount: 300, currency: "EUR")
      [ observed_on, Date.current ].each do |date|
        ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 2)
      end

      2.times do
        materialize(window_start_date: observed_on)
        current = @account.current_holdings.find_by!(security: @other)
        assert_equal "EUR", current.currency
        assert_equal 3, current.qty
        assert_equal 1700, @account.reload.balance
      end
      assert old_copy.reload.superseded?
      assert_equal 45, old_copy.cost_basis
      assert old_copy.cost_basis_locked?

      new_snapshot.destroy!
      materialize(window_start_date: observed_on)
      assert_equal old_copy, @account.current_holdings.find_by!(security: @other)
      refute old_copy.reload.superseded?
      assert_equal 45, old_copy.cost_basis
    end
  end

  test "deleting the last trade preserves an independently imported holding" do
    @account.create_cash_anchor!
    trade = @account.entries.create!(date: Date.current, amount: 200, currency: "USD", name: "Buy MSFT",
      entryable: Trade.new(security: @other, qty: 2, price: 100, currency: "USD", investment_activity_label: "Buy"))
    materialize
    assert @account.current_holdings.find_by!(security: @other).materialized?

    snapshot = @account.holdings.create!(security: @other, date: Date.current.next_day,
      qty: 3, price: 100, amount: 300, currency: "USD", materialized: false)
    trade.destroy!
    materialize(window_start_date: trade.date)

    assert Holding.exists?(snapshot.id)
    assert_nil @account.current_holdings.find_by(security: @other)
    travel 1.day do
      materialize
      assert_equal snapshot.id, @account.current_holdings.find_by!(security: @other).id
    end
  end

  test "a future materialization window keeps only effective trades in the lot book" do
    @account.create_cash_anchor!
    today = Date.current
    buy = @account.entries.create!(date: today, amount: 200, currency: "USD", name: "Buy MSFT",
      entryable: Trade.new(security: @other, qty: 2, price: 100, currency: "USD", investment_activity_label: "Buy"))
    @account.entries.create!(date: today.next_day, amount: 300, currency: "USD", name: "Scheduled MSFT buy",
      entryable: Trade.new(security: @other, qty: 3, price: 100, currency: "USD", investment_activity_label: "Buy"))

    materialize(window_start_date: today + 2.days)

    lots = HoldingLot.where(account: @account, security: @other)
    assert_equal [ [ buy.id, 2 ] ], lots.pluck(:source_entry_id, :qty)
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

  test "a future imported holding survives sync and becomes current on its date" do
    @account.create_cash_anchor!
    date = Date.current.next_day
    snapshot = { type: "Holding", data: {
      account_id: "source-account", ticker: @other.ticker, date: date, qty: 2, price: 100, amount: 200, currency: "USD"
    } }
    Family::DataImporter.new(@account.family, snapshot.to_json, account_targets: { "source-account" => @account }).import!
    imported = @account.holdings.find_by!(date: date)
    refute imported.materialized?
    report = Holding::CurrentForInvestmentAccounts.new([ @account.id ])

    materialize
    assert Holding.exists?(imported.id)
    assert_not_includes @account.current_holdings, imported
    assert_not_includes report.relation, imported
    assert_equal 1100, @account.reload.balance
    refute @account.balances.exists?(date: date)

    travel 1.day do
      materialize
      assert_includes @account.current_holdings, imported
      assert_includes report.relation, imported
      refute imported.reload.materialized?
      assert_equal 1300, @account.reload.balance
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

  test "an income trade neither stops nor removes a carried snapshot" do
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")
    @account.create_cash_anchor!
    dividend = @account.entries.create!(date: Date.current, amount: -5, currency: "USD", name: "Dividend",
      entryable: Trade.new(security: @other, qty: 0, price: 0, currency: "USD", investment_activity_label: "Dividend"))
    travel 1.day do
      materialize
      assert_equal 2, @account.current_holdings.find_by!(security: @other).qty

      dividend.destroy!
      materialize
      assert_equal 2, @account.current_holdings.find_by!(security: @other).qty
    end
  end

  test "a split after the last quote scales carried positions without moving their value" do
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD", cost_basis: 50)
    @account.create_cash_anchor!
    travel 1.day do
      [ @aapl, @other ].each do |security|
        Security::Split.create!(security: security, ex_date: Date.current, numerator: 2, denominator: 1, source: "manual")
      end
      materialize
      carried = @account.current_holdings.find_by!(security: @other)
      assert_equal 4, carried.qty
      assert_equal 25, carried.cost_basis
      assert_equal 20, @account.current_holdings.find_by!(security: @aapl).qty
      assert_equal 1300, @account.reload.balance
    end
  end

  test "adding or correcting a split rebuilds an existing carried position" do
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", cost_basis: 60, cost_basis_source: "manual", cost_basis_locked: true)
    @account.create_cash_anchor!

    travel 1.day do
      materialize
      carried = @account.current_holdings.find_by!(security: @other)
      assert_predicate carried, :materialized?
      assert_equal 2, carried.qty

      split = Security::Split.create!(security: @other, ex_date: Date.current, numerator: 2, denominator: 1, source: "manual")
      materialize(window_start_date: split.ex_date)
      assert_equal 4, carried.reload.qty
      assert_equal 50, carried.price
      assert_equal 30, carried.cost_basis

      split.update!(numerator: 3)
      materialize(window_start_date: split.ex_date)
      holding = @account.current_holdings.find_by!(security: @other)
      assert_equal 6, holding.qty
      assert_equal 20, holding.cost_basis
      assert_in_delta 200, holding.amount, 0.01
      assert holding.cost_basis_locked?
    end
  end

  test "a corrected snapshot quantity keeps its unit basis and respects a later manual override" do
    snapshot = @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", cost_basis: 60, cost_basis_source: "manual", cost_basis_locked: true)
    @account.create_cash_anchor!

    travel 1.day do
      materialize
      carried = @account.current_holdings.find_by!(security: @other)

      snapshot.update!(qty: 3, amount: 300)
      materialize
      assert_equal 3, carried.reload.qty
      assert_equal 60, carried.cost_basis

      carried.set_manual_cost_basis!(45)
      snapshot.update!(qty: 4, amount: 400, cost_basis: 50)
      materialize
      assert_equal 4, carried.reload.qty
      assert_equal 45, carried.cost_basis
      assert carried.cost_basis_locked?
    end
  end

  test "a carried provider snapshot becomes a calculated row that keeps being repriced" do
    coinstats_item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: @account, provider: coinstats_item.coinstats_accounts.create!(name: "Wallet", currency: "USD"))
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD", account_provider_id: provider.id)
    @account.create_cash_anchor!
    travel 1.day do
      price = @other.prices.create!(date: Date.current, price: 120, currency: "USD")
      materialize
      assert_nil @account.holdings.find_by!(security: @other, date: Date.current).account_provider_id

      price.update!(price: 130)
      materialize
      assert_equal 260, @account.holdings.find_by!(security: @other, date: Date.current).amount
      # Investment reports read the carried row too, not the original snapshot.
      assert_equal 260, Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation.find_by!(security: @other).amount

      # A provider row dated after today stays out, as in Account#current_holdings.
      @account.holdings.create!(security: @other, date: Date.current.next_day, qty: 9, price: 100, amount: 900, currency: "USD", account_provider_id: provider.id)
      assert_equal 260, Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation.find_by!(security: @other).amount
    end
  end

  test "an explicit empty SimpleFIN snapshot replaces carried positions and preserves independent holdings" do
    item = @account.family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/access")
    simplefin = item.simplefin_accounts.create!(name: "Brokerage", account_type: "investment", account_id: "brokerage",
      currency: "USD", current_balance: 1130)
    provider = AccountProvider.create!(account: @account, provider: simplefin)
    second_security = Security.create!(ticker: "SECOND", name: "Another observed security")
    manual_security = Security.create!(ticker: "MANUAL", name: "Independent security")
    first_snapshot = @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", account_provider_id: provider.id)
    @account.holdings.create!(security: manual_security, date: Date.current, qty: 1, price: 30, amount: 30, currency: "USD")
    @account.create_cash_anchor!

    travel 1.day do
      @account.holdings.create!(security: second_security, date: Date.current, qty: 1, price: 50, amount: 50,
        currency: "USD", account_provider_id: provider.id)
      materialize
      assert_equal 2, @account.current_holdings.find_by!(security: @other).qty
      assert_equal 1380, @account.reload.balance
    end

    travel 2.days do
      materialize
      calculated = @account.current_holdings.find_by!(security: @other)
      calculated.set_manual_cost_basis!(45)

      simplefin.update!(raw_holdings_payload: [])
      SimplefinHoldingsApplyJob.perform_now(simplefin.id)

      closed = calculated.reload
      assert_equal provider.id, closed.account_provider_id
      assert_equal 0, closed.qty
      assert_equal 45, closed.cost_basis
      assert_predicate closed, :cost_basis_locked?
      refute_predicate closed, :materialized?

      materialize
      assert_nil @account.current_holdings.find_by(security: @other)
      assert_equal 1130, @account.reload.balance

      Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
      report = Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
      assert_nil report.find_by(security: @other)
      assert_nil report.find_by(security: second_security)
      assert_equal 1, report.find_by!(security: manual_security).qty
      assert_equal 2, first_snapshot.reload.qty
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

  test "an empty incremental window purges the stale tail and keeps imported history" do
    @account.entries.trades.destroy_all
    @account.holdings.delete_all
    travel_to(2.days.ago) { @account.create_cash_anchor! }
    cash_entry(amount: 1, date: Date.yesterday)
    latest = cash_entry(amount: 1)
    imported = @account.balances.create!(date: 10.days.ago.to_date, currency: "USD", balance: 10, cash_balance: 10)
    materialize
    assert @account.balances.exists?(id: imported.id)
    assert @account.balances.exists?(date: latest.date)

    latest.destroy!
    materialize(window_start_date: latest.date)

    assert @account.balances.exists?(id: imported.id)
    assert_not @account.balances.exists?(date: latest.date)
  end

  test "a full replay purges the empty window without deleting imported history" do
    @account.entries.trades.destroy_all
    @account.holdings.delete_all
    @account.balances.delete_all
    @account.update!(currency: "EUR")
    @account.entries.valuations.first.update!(currency: "EUR")
    travel_to(2.days.ago) { @account.create_cash_anchor! }
    cash_entry(amount: 1, date: Date.yesterday, currency: "EUR")
    latest = cash_entry(amount: 1, currency: "EUR")
    imported = @account.balances.create!(date: 10.days.ago.to_date, currency: "EUR", balance: 10, cash_balance: 10)
    materialize
    assert @account.balances.exists?(date: latest.date)

    latest.destroy!
    materialize(window_start_date: latest.date)

    assert @account.balances.exists?(id: imported.id)
    assert_not @account.balances.exists?(date: latest.date)
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
