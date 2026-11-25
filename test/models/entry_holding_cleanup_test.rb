require "test_helper"

class EntryHoldingCleanupTest < ActiveSupport::TestCase
  setup do
    @account = families(:empty).accounts.create!(name: "Investment", balance: 1000, cash_balance: 1000,
      currency: "USD", accountable: Investment.new)
    @security = securities(:msft)
    @account.create_cash_anchor!
  end

  test "deleting several trades before syncing clears holdings older than the last deleted trade" do
    first_trade = buy(Date.yesterday, qty: 1)
    last_trade = buy(Date.current, qty: 2)
    materialize(first_trade.date)
    derived = @account.holdings.find_by!(security: @security, date: first_trade.date)
    assert_equal 1, derived.qty

    first_trade.destroy!
    last_trade.destroy!

    assert_nil @account.current_holdings.find_by(security: @security)
    assert_predicate derived.reload, :superseded?
    last_trade.account.expects(:sync_later).with(window_start_date: first_trade.date)
    last_trade.sync_account_later
  end

  test "keeps a manual cost edit on earlier carried history when a trade is removed" do
    source = @account.holdings.create!(security: @security, date: Date.current - 2, currency: "USD", price: 100, qty: 3, amount: 300)
    trade = buy(Date.current, qty: 2)
    materialize(source.date)
    carry = @account.holdings.find_by!(security: @security, date: Date.yesterday)
    assert_predicate carry, :materialized?
    carry.set_manual_cost_basis!(75)

    trade.destroy!
    materialize(carry.date)

    assert_equal 75, carry.reload.cost_basis
    assert_equal 3, carry.qty
    assert_equal 3, @account.current_holdings.find_by!(security: @security).qty
    assert Holding.exists?(source.id)
  end

  private
    def buy(date, qty:)
      @account.entries.create!(date: date, amount: 100 * qty, currency: "USD", name: "Buy MSFT",
        entryable: Trade.new(security: @security, qty: qty, price: 100, currency: "USD", investment_activity_label: "Buy"))
    end

    def materialize(start_date)
      Balance::Materializer.new(@account, strategy: :forward, window_start_date: start_date).materialize_balances
    end
end
