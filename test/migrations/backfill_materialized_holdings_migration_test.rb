require "test_helper"
require Rails.root.join("db/migrate/20261122123000_backfill_materialized_holdings")

class BackfillMaterializedHoldingsMigrationTest < ActiveSupport::TestCase
  setup do
    @account = families(:empty).accounts.create!(name: "Legacy portfolio", balance: 1000, cash_balance: 1000,
      currency: "USD", accountable: Investment.new)
    @security = securities(:msft)
    [ Date.yesterday, Date.current ].each do |date|
      @security.prices.find_or_initialize_by(date: date).update!(price: 100, currency: "USD")
    end
    @trade = @account.entries.create!(date: Date.yesterday, amount: 200, currency: "USD", name: "Buy MSFT",
      entryable: Trade.new(security: @security, qty: 2, price: 100, currency: "USD", investment_activity_label: "Buy"))
    Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    @account.holdings.update_all(materialized: false)
  end

  test "backfills journal history and lets deletion remove the position before another sync" do
    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    assert_equal @account.balances.find_by!(date: Date.current).created_at, holding.created_at
    HoldingLot.where(account: @account).delete_all

    run_migration
    assert_predicate holding.reload, :materialized?

    @account.create_cash_anchor!
    @trade.destroy!
    Balance::Materializer.new(@account, strategy: :forward, window_start_date: @trade.date).materialize_balances

    refute Holding.exists?(holding.id)
    assert_nil @account.current_holdings.find_by(security: @security)
  end

  test "preserves an independently imported legacy holding with the same values and a calculated basis" do
    @account.holdings.find_by!(security: @security, date: Date.current).destroy!
    observation = @account.holdings.create!(security: @security, date: Date.current, qty: 2, price: 100, amount: 200,
      currency: "USD", cost_basis: 100, cost_basis_source: "calculated")
    refute_equal @account.balances.find_by!(date: Date.current).created_at, observation.created_at

    run_migration
    refute_predicate observation.reload, :materialized?

    @account.create_cash_anchor!
    @trade.destroy!
    Balance::Materializer.new(@account, strategy: :forward, window_start_date: @trade.date).materialize_balances

    assert_equal observation.id, @account.current_holdings.find_by!(security: @security).id
    assert_equal 2, observation.reload.qty
  end

  test "preserves a legacy snapshot imported over a row that was originally calculated" do
    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    holding.update!(qty: 3, amount: 300)

    run_migration

    refute_predicate holding.reload, :materialized?
  end

  private
    def run_migration
      ActiveRecord::Migration.suppress_messages { BackfillMaterializedHoldings.new.up }
    end
end
