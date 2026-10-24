# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261024210000_add_cost_basis_carried_to_holdings")

class AddCostBasisCarriedToHoldingsMigrationTest < ActiveSupport::TestCase
  # Before the column, the provider import copied a lock forward onto each
  # new day's row. Those copies are marked carried; the user's own lock, and
  # a later lock at a different figure, are not.
  test "the backfill marks locks copied forward at the same figure as carried" do
    account = families(:empty).accounts.create!(name: "Linked", balance: 0, currency: "USD", accountable: Investment.new)
    security = Security.create!(ticker: "BKFL", name: "Backfill")
    rows = [ [ 4, 42, true ], [ 3, 42, true ], [ 2, 50, true ], [ 1, 50, false ] ].map do |days_ago, cost, locked|
      account.holdings.create!(security: security, date: days_ago.days.ago.to_date, qty: 1, price: 10, amount: 10,
                               currency: "USD", cost_basis: cost, cost_basis_source: "manual", cost_basis_locked: locked)
    end

    ActiveRecord::Base.connection.execute(AddCostBasisCarriedToHoldings.backfill_sql)

    assert_equal [ false, true, false, false ], rows.map { |row| row.reload.cost_basis_carried? }
  end
end
