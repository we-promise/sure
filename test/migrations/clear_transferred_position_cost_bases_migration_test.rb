# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260826090000_clear_transferred_position_cost_bases")

# The migration exists to clear figures the app fabricated for positions it
# could not know the cost of. Which positions those are is decided at runtime by
# `Holding#calculate_avg_cost` and the calculators, and the migration has to
# agree with them — it destroys data and cannot be undone.
class ClearTransferredPositionCostBasesMigrationTest < ActiveSupport::TestCase
  setup do
    @holding = holdings(:one)
    @account = @holding.account
    # Everything already there is an ordinary purchase; the transfer under test
    # is the only one.
    @account.trades.update_all(investment_activity_label: "Buy")
    # Left empty so `avg_cost` reports the computed figure rather than a stored
    # one; each test stores what the migration is then asked to judge.
    @holding.update_columns(cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)
  end

  test "a position transferred in loses the figure the app worked out" do
    transfer(qty: 5)

    assert_nil @holding.reload.avg_cost, "the runtime already treats this position as unknowable"
    store_calculated_basis

    run_migration

    assert_nil @holding.reload.cost_basis
    assert_nil @holding.reload.cost_basis_source
  end

  # The runtime only invalidates on a transfer IN: both `calculate_avg_cost` and
  # the calculators drop `qty <= 0` rows before they ever look at the label.
  # Shares sent elsewhere leave the remaining ones with the cost they were
  # actually bought at, and that figure is correct.
  test "a position transferred out keeps it" do
    transfer(qty: -5)

    assert_not_nil @holding.reload.avg_cost, "the runtime keeps the basis after an outbound transfer"
    store_calculated_basis

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d,
                 "an outbound transfer destroyed a basis the app still stands behind"
  end

  test "a figure the user asserted is not the app's to discard" do
    transfer(qty: 5)
    @holding.update_columns(cost_basis: 100, cost_basis_source: "manual")

    run_migration

    assert_equal 100, @holding.reload.cost_basis.to_d
  end

  private
    def store_calculated_basis
      @holding.update_columns(cost_basis: 100, cost_basis_source: "calculated")
    end

    def transfer(qty:)
      @account.entries.create!(
        date: @holding.date - 1,
        name: "Moved #{qty} units",
        amount: -100,
        currency: @holding.currency,
        entryable: Trade.new(
          security: @holding.security,
          qty: qty,
          price: 100,
          currency: @holding.currency,
          investment_activity_label: Trade::TRANSFER_LABEL
        )
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        ClearTransferredPositionCostBases.new.up
      end
    end
end
