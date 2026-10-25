# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261024210000_add_cost_basis_carried_to_holdings")

class AddCostBasisCarriedToHoldingsMigrationTest < ActiveSupport::TestCase
  # Before the column, the provider import copied a lock forward onto each
  # new day's row. Those copies are marked carried; the user's own lock, and
  # a later lock at a different figure, are not.
  test "the backfill marks locks copied forward at the same figure as carried" do
    rows = position([ [ 4, 42, true ], [ 3, 42, true ], [ 2, 50, true ], [ 1, 50, false ] ], provider: true)

    backfill

    assert_equal [ false, true, false, false ], rows.map { |row| row.reload.cost_basis_carried? }
  end

  # Calculated rows were never copied forward, so a user who locked two of
  # them at the same figure set two locks of their own.
  test "the backfill leaves a same-figure lock on rows the provider did not write" do
    rows = position([ [ 4, 42, true ], [ 3, 42, true ] ], provider: false)

    backfill

    assert_equal [ false, false ], rows.map { |row| row.reload.cost_basis_carried? }
  end

  # The import copies a lock only from the same provider's earlier rows.
  test "the backfill leaves a lock another provider's row happens to share" do
    rows = position([ [ 4, 42, true ], [ 3, 42, true ] ], provider: true)
    # Another provider's link; an account holds one per provider type, and
    # the backfill compares only which link wrote each row.
    other = families(:empty).accounts.create!(name: "Other #{SecureRandom.hex(2)}", balance: 0, currency: "USD", accountable: Investment.new)
    rows.second.update_columns(account_provider_id: provider_for(other).id)

    backfill

    assert_not rows.second.reload.cost_basis_carried?
  end

  # A row from another source in between is not the previous row the import
  # read, so the copy behind it is still found.
  test "the backfill finds a copy past a row from another source" do
    rows = position([ [ 4, 42, true ], [ 3, 99, false ], [ 2, 42, true ] ], provider: true)
    rows.second.update_columns(account_provider_id: nil)

    backfill

    assert rows.third.reload.cost_basis_carried?
  end

  # The import copies a lock only from an earlier provider row, so a provider
  # row locked after a calculated one at that figure is the user's own.
  test "the backfill leaves a provider row whose previous locked row the provider did not write" do
    rows = position([ [ 4, 42, true ], [ 3, 42, true ] ], provider: true)
    rows.first.update_columns(account_provider_id: nil)

    backfill

    assert_not rows.second.reload.cost_basis_carried?
  end

  private

    def position(rows, provider:)
      account = families(:empty).accounts.create!(name: "Linked #{SecureRandom.hex(2)}", balance: 0, currency: "USD", accountable: Investment.new)
      account_provider = provider_for(account) if provider
      security = Security.create!(ticker: "BKF#{SecureRandom.hex(2).upcase}", name: "Backfill")
      rows.map do |days_ago, cost, locked|
        account.holdings.create!(security: security, date: days_ago.days.ago.to_date, qty: 1, price: 10, amount: 10, currency: "USD",
                                 cost_basis: cost, cost_basis_source: "manual", cost_basis_locked: locked, account_provider: account_provider)
      end
    end

    def provider_for(account)
      item = families(:empty).coinstats_items.create!(name: "CS #{SecureRandom.hex(2)}", api_key: "k")
      AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "P", currency: "USD"))
    end

    def backfill
      ActiveRecord::Base.connection.execute(AddCostBasisCarriedToHoldings.backfill_sql)
    end
end
