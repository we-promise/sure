# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261024210000_add_cost_basis_carried_to_holdings")

class AddCostBasisCarriedToHoldingsMigrationTest < ActiveSupport::TestCase
  # A lock the import copied forward and one the user set at the same figure
  # look identical, and after a buy the second is a new opening basis. Nothing
  # stored tells them apart, so no existing row is marked.
  test "the migration marks no existing lock as carried, even a same-figure lock after a buy" do
    rows = provider_position([ [ 4, 42 ], [ 3, 42 ], [ 2, 42 ] ])
    buy_after(rows.first)

    flags, locks, costs = after_rerunning_the_migration { rows.map { |row| row.reload.then { |r| [ r.cost_basis_carried?, r.cost_basis_locked?, r.cost_basis.to_i ] } }.transpose }

    assert_equal [ false, false, false ], flags
    assert_equal [ true, true, true ], locks
    assert_equal [ 42, 42, 42 ], costs
  end

  private

    def provider_position(rows)
      account = families(:empty).accounts.create!(name: "Linked #{SecureRandom.hex(2)}", balance: 0, currency: "USD", accountable: Investment.new)
      item = families(:empty).coinstats_items.create!(name: "CS #{SecureRandom.hex(2)}", api_key: "k")
      account_provider = AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "P", currency: "USD"))
      security = Security.create!(ticker: "BKF#{SecureRandom.hex(2).upcase}", name: "Backfill")
      rows.map do |days_ago, cost|
        account.holdings.create!(security: security, date: days_ago.days.ago.to_date, qty: 1, price: 10, amount: 10, currency: "USD",
                                 cost_basis: cost, cost_basis_source: "manual", cost_basis_locked: true, account_provider: account_provider)
      end
    end

    def buy_after(first)
      first.account.entries.create!(name: "Buy", date: first.date + 1.day, amount: 10, currency: "USD",
                                    entryable: Trade.new(security: first.security, qty: 1, price: 10, currency: "USD"))
    end

    # Reruns it inside a rolled-back savepoint: the column comes back last, and
    # prepared statements must not outlive that on this connection.
    def after_rerunning_the_migration
      connection = ActiveRecord::Base.connection
      result = nil
      connection.transaction(requires_new: true) do
        ActiveRecord::Migration.suppress_messages do
          AddCostBasisCarriedToHoldings.new.exec_migration(connection, :down)
          AddCostBasisCarriedToHoldings.new.exec_migration(connection, :up)
        end
        connection.clear_cache!
        Holding.reset_column_information
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    ensure
      connection.clear_cache!
      Holding.reset_column_information
    end
end
