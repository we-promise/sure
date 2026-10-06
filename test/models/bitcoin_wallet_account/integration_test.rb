require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::IntegrationTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @account = accounts(:crypto)
    @account.entries.destroy_all
    @account.holdings.destroy_all
    @account.balances.destroy_all
    @account.update!(cash_balance: 100, balance: 1100)
    @wallet = build_bitcoin_wallet(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    manual_bitcoin_source(@wallet)
    @account.holdings.create!(security: @wallet.security, date: Date.current.prev_day, qty: "0.1",
      price: 10_000, amount: 1000, currency: "USD", cost_basis: 2000, cost_basis_source: "manual")
    @other = securities(:aapl)
    @other.prices.find_or_initialize_by(date: Date.current).update!(price: 100, currency: "USD")
  end

  test "foreign cash movements use the standard dated exchange rate" do
    @wallet.connect!
    ExchangeRate.find_or_initialize_by(from_currency: "EUR", to_currency: "USD", date: Date.current).update!(rate: "1.2")
    cash_entry(amount: 10, currency: "EUR")
    materialize
    assert_equal 88, @account.reload.cash_balance
    assert_equal 2088, @account.balance
  end

  test "manual trade exchange rates are retained in cash and basis" do
    @wallet.connect!
    trade = Trade.new(security: @other, qty: 2, price: 10, currency: "EUR", exchange_rate: 2)
    @account.entries.create!(date: Date.current, amount: 20, currency: "EUR", name: "Buy", entryable: trade)
    materialize
    assert_equal 60, @account.reload.cash_balance
    assert_equal 20, @account.current_holdings.find_by!(security: @other).cost_basis
  end

  test "split parents are excluded from cash and flows" do
    @wallet.connect!
    cash_entry(amount: 100).split!([ { name: "First", amount: 40 }, { name: "Second", amount: 60 } ])
    materialize
    assert_equal 0, @account.reload.cash_balance
    assert_equal 100, @account.balances.find_by!(date: Date.current).cash_outflows
  end

  test "a later absolute valuation on the connection day overrides the cash anchor" do
    @wallet.connect!
    travel 1.second do
      @account.entries.create!(date: Date.current, amount: 3000, currency: "USD", name: "Total valuation", entryable: Valuation.new)
      materialize
      assert_equal 3000, @account.reload.balance
      assert_equal 1000, @account.cash_balance
    end
  end

  test "an existing valuation on the connection day does not replace preserved cash" do
    @account.entries.create!(date: Date.current, amount: 1100, currency: "USD", name: "Old total", entryable: Valuation.new)
    travel 1.second do
      @wallet.connect!
      assert_equal 100, @account.reload.cash_balance
      assert_equal 2100, @account.balance
    end
  end

  test "the public reconciliation workflow keeps a total valuation distinct from the cash anchor" do
    @wallet.connect!
    travel 1.second do
      result = @account.create_reconciliation(balance: 3000, date: Date.current)
      assert result.success?, result.error_message
      materialize
      assert_equal 3000, @account.reload.balance
      assert_equal 1000, @account.cash_balance
      assert_equal 1, @account.valuations.cash_anchor.count
      assert_equal 1, @account.valuations.reconciliation.count
    end
  end

  test "editing the cash anchor establishes a new absolute cash value" do
    entry = cash_entry(amount: 10, date: Date.current.prev_day)
    @wallet.connect!
    entry.update!(amount: 20)
    anchor = @account.entries.valuations.find_by!(entryable_id: Valuation.cash_anchor.select(:id))
    result = @account.update_reconciliation(anchor, balance: 200, date: Date.current)
    assert result.success?, result.error_message
    materialize
    assert_equal 200, @account.reload.cash_balance
  end

  test "editing a preconnection cash movement applies its delta through the anchor" do
    entry = cash_entry(amount: 10, date: Date.current.prev_day)
    @wallet.connect!
    entry.update!(amount: 20)
    materialize(window_start_date: entry.date)
    assert_equal 90, @account.reload.cash_balance
  end

  test "backdated new cash movements are included once" do
    @wallet.connect!
    cash_entry(amount: 15, date: 3.days.ago.to_date)
    2.times { materialize(window_start_date: 3.days.ago.to_date) }
    assert_equal 85, @account.reload.cash_balance
  end

  test "manual tracking after disconnect preserves cash and quantity" do
    @wallet.connect!
    cash_entry(amount: 10)
    materialize
    @wallet.disconnect!
    @account.reload
    materialize
    assert_equal 90, @account.reload.cash_balance
    assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: @wallet.security).qty
  end

  test "new manual assets are not copied backward and existing rows are repriced" do
    @wallet.connect!
    connected = Date.current
    travel 1.day do
      @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")
      @other.prices.create!(date: Date.current, price: 120, currency: "USD")
      materialize
      assert_equal 240, @account.current_holdings.find_by!(security: @other).amount
      assert_empty @account.holdings.where(security: @other, date: ..connected).where.not(qty: 0)
    end
  end

  test "untraded foreign holdings are valued in the account currency" do
    ExchangeRate.find_or_initialize_by(from_currency: "EUR", to_currency: "USD", date: Date.current).update!(rate: 2)
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 30, amount: 60, currency: "EUR")
    @other.prices.find_by!(date: Date.current).update!(price: 30, currency: "EUR")
    @wallet.connect!
    assert_equal 2220, @account.reload.balance
    assert_equal 60, @account.current_holdings.find_by!(security: @other).amount
    assert_equal "EUR", @account.current_holdings.find_by!(security: @other).currency
  end

  test "manual basis and locks survive carrying an untraded asset" do
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", cost_basis: 50, cost_basis_source: "manual", cost_basis_locked: true, security_locked: true)
    @wallet.connect!
    travel 1.day do
      materialize
      holding = @account.current_holdings.find_by!(security: @other)
      assert_equal 50, holding.cost_basis
      assert holding.cost_basis_locked?
      assert holding.security_locked?
    end
  end

  test "calculated basis changes and becomes unknown after a transfer" do
    @wallet.connect!
    asset_trade(qty: 2, price: 50, amount: 100)
    materialize
    assert_equal 50, @account.current_holdings.find_by!(security: @other).cost_basis
    asset_trade(qty: 1, price: 100, amount: 0, label: Trade::TRANSFER_LABEL)
    materialize
    assert_nil @account.current_holdings.find_by!(security: @other).cost_basis
  end

  test "deleting an unrelated manual position removes its series permanently" do
    @account.holdings.create!(security: @other, date: Date.current.prev_day, qty: 2, price: 100, amount: 200, currency: "USD")
    @wallet.connect!
    @account.current_holdings.find_by!(security: @other).destroy_holding_and_entries!
    materialize
    assert_empty @account.holdings.where(security: @other)
  end

  test "an earlier BTC holding cannot delete the active journal or be remapped" do
    old = @account.holdings.find_by!(security: @wallet.security)
    @wallet.connect!
    before = @account.trades.count
    assert_raises(ArgumentError) { old.destroy_holding_and_entries! }
    assert_raises(ArgumentError) { old.remap_security!(@other) }
    assert_equal before, @account.trades.count
    assert_equal @wallet.security_id, old.reload.security_id
  end

  test "provider quantity cannot be manually changed while other trades remain available" do
    @wallet.connect!
    assert @account.supports_trades?
    entry = @account.entries.new(date: Date.current, amount: 100, currency: "USD", name: "Manual BTC buy",
      entryable: Trade.new(security: @wallet.security, qty: "0.01", price: 10_000, currency: "USD"))
    refute entry.save
    assert_match(/managed/i, entry.errors.full_messages.join)
    asset_trade(qty: 1, price: 100, amount: 100)
  end

  test "refreshing quotes uses shared materialization without changing provider quantity" do
    @wallet.connect!
    @wallet.security.prices.find_by!(date: Date.current).update!(price: 12_000)
    materialize
    holding = @account.current_holdings.find_by!(security: @wallet.security)
    assert_equal BigDecimal("0.2"), holding.qty
    assert_equal 2400, holding.amount
    assert_equal 2500, @account.reload.balance
  end

  test "a full provider cash snapshot preserves the Bitcoin position" do
    @wallet.connect!
    @account.apply_provider_balance!(balance: 300, cash_balance: 50)
    cash_entry(amount: -25)
    materialize
    assert_equal 50, @account.reload.cash_balance
    assert_equal 2050, @account.balance
    cash_entry(amount: 10)
    materialize
    assert_equal 40, @account.reload.cash_balance
  end

  test "full provider totals are scoped and do not freeze Bitcoin market value" do
    link = @account.account_providers.create!(provider: kraken_accounts(:one))
    @account.holdings.create!(security: @other, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", account_provider: link)
    @wallet.connect!
    result = @account.set_current_balance(300, provider_balance: true)
    assert result.success?, result.error
    materialize
    assert_equal 100, @account.reload.cash_balance
    assert_equal 2300, @account.balance
    @wallet.security.prices.find_by!(date: Date.current).update!(price: 12_000)
    materialize
    assert_equal 2700, @account.reload.balance
  end

  test "a complete provider snapshot omitting an asset does not resurrect it" do
    link = @account.account_providers.create!(provider: kraken_accounts(:one))
    @account.holdings.create!(security: @other, date: Date.current.prev_day, qty: 2, price: 100, amount: 200,
      currency: "USD", account_provider: link)
    remaining = Security.create!(ticker: "TEST:REMAINING", name: "Remaining asset", offline: true)
    remaining.prices.create!(date: Date.current, price: 50, currency: "USD")
    @account.holdings.create!(security: remaining, date: Date.current, qty: 1, price: 50, amount: 50,
      currency: "USD", account_provider: link)
    @wallet.connect!
    refute @account.current_holdings.exists?(security: @other)
    assert @account.current_holdings.exists?(security: remaining)
  end

  test "a managed position takes precedence over a newer complete provider row" do
    @wallet.connect!
    managed = @account.current_holdings.find_by!(security: @wallet.security)
    link = @account.account_providers.create!(provider: kraken_accounts(:one))
    travel 1.day do
      @account.holdings.create!(security: @wallet.security, date: Date.current, qty: "0.9",
        price: 10_000, amount: 9000, currency: "USD", account_provider: link)
      other = @account.holdings.create!(security: @other, date: Date.current, qty: 1,
        price: 100, amount: 100, currency: "USD", account_provider: link)
      assert_equal managed.id, @account.current_holdings.find_by!(security: @wallet.security).id
      assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: @wallet.security).qty
      assert @account.current_holdings.exists?(id: other.id)
    end
  end

  test "notes on a superseded valuation do not restore its old total" do
    old = @account.entries.create!(date: Date.current, amount: 1100, currency: "USD", name: "Old total", entryable: Valuation.new)
    @wallet.connect!
    old.update!(notes: "Keep this historical note")
    materialize
    assert_equal 2100, @account.reload.balance
  end

  test "a pending account sync cannot be borrowed by a different wallet parent" do
    @wallet.connect!
    first = @wallet.syncs.create!
    second = @wallet.syncs.create!
    one = @account.sync_later(parent_sync: first)
    two = @account.sync_later(parent_sync: second)
    refute_equal one.id, two.id
    assert_equal first.id, one.parent_id
    assert_equal second.id, two.parent_id
    assert_equal two.id, @account.sync_later(parent_sync: second).id
  end

  test "an in-flight account sync always gets a follow-up for later data" do
    @wallet.connect!
    first = @account.syncs.create!(status: "syncing")
    next_sync = @account.sync_later
    refute_equal first.id, next_sync.id
    assert next_sync.pending?
  end

  test "zero quantity income is cash only and reconciliation is not market profit" do
    @wallet.connect!
    asset_trade(qty: 0, price: 0, amount: -5, label: "Dividend")
    materialize
    balance = @account.balances.find_by!(date: Date.current)
    assert_equal 105, @account.reload.cash_balance
    assert_equal 0, balance.non_cash_outflows
    travel 1.day do
      @wallet.update!(balance_sats: 30_000_000)
      BitcoinWalletAccount::Processor.new(@wallet).process
      balance = @account.balances.find_by!(date: Date.current)
      assert_equal 0, balance.net_market_flows
      assert_equal 1000, balance.non_cash_adjustments
    end
  end

  test "price provider absence falls back to a known manual holding quote" do
    @wallet.security.prices.delete_all
    @wallet.security.stubs(:price_data_provider).returns(nil)
    @wallet.connect!
    assert_equal 2100, @account.reload.balance
    assert_equal 10_000, @account.current_holdings.find_by!(security: @wallet.security).price
  end

  test "a missing quote retains the last account valuation and reports diagnostics" do
    @account.holdings.destroy_all
    @wallet.security.prices.delete_all
    @wallet.security.stubs(:price_data_provider).returns(nil)
    @wallet.connect!
    assert_equal 1100, @account.reload.balance
    assert_equal "MissingPrice", @wallet.reload.last_error
    assert_empty @account.holdings
  end

  test "both individual and aggregate charts retain manual history" do
    old_date = 5.days.ago.to_date
    @account.balances.create!(date: old_date, currency: "USD", balance: 1100, cash_balance: 100)
    @wallet.connect!
    period = Period.last_30_days
    assert @account.balance_series(period: period).values.any? { |point| point.date == old_date }
    series = Balance::LinkedInvestmentSeriesNormalizer.aggregate_accounts(accounts: [ @account ], currency: "USD", period: period, favorable_direction: "up")
    assert series.values.any? { |point| point.date == old_date }
  end

  test "a year of mixed history is preserved outside each materialization window" do
    start_date = Date.current - 365
    @account.holdings.update_all(date: start_date.prev_day)
    travel_to start_date.noon do
      @wallet.update!(last_synced_at: Time.current)
      @wallet.security.prices.create!(date: Date.current, price: 10_000, currency: "USD")
      @wallet.connect!
    end
    materialize(window_start_date: start_date)
    assert_equal 366, @account.balances.count
    assert_equal 2100, @account.reload.balance

    history = @account.balances.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)
    holdings = @account.holdings.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)
    BitcoinWalletAccount::Processor.new(@wallet).process
    assert_equal history, @account.balances.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)
    assert_equal holdings, @account.holdings.where(date: ...Date.current).order(:date).pluck(:id, :updated_at)

    edit_date = 30.days.ago.to_date
    earlier = @account.balances.where(date: ...edit_date).order(:date).pluck(:id, :updated_at)
    cash_entry(amount: 5, date: edit_date)
    materialize(window_start_date: edit_date)
    assert_equal earlier, @account.balances.where(date: ...edit_date).order(:date).pluck(:id, :updated_at)
    assert_equal 95, @account.reload.cash_balance
    assert_equal 2095, @account.balance
  end

  private
    def cash_entry(amount:, currency: "USD", date: Date.current)
      @account.entries.create!(date: date, amount: amount, currency: currency, name: "Cash movement", entryable: Transaction.new)
    end

    def asset_trade(qty:, price:, amount:, label: "Buy")
      @account.entries.create!(date: Date.current, amount: amount, currency: "USD", name: "Asset movement",
        entryable: Trade.new(security: @other, qty: qty, price: price, currency: "USD", investment_activity_label: label))
    end

    def materialize(**options)
      Balance::Materializer.new(@account, strategy: @account.balance_calculation_strategy, **options).materialize_balances
    end
end
