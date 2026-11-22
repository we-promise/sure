# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261121100100_backfill_carried_forward_on_security_prices")

class BackfillCarriedForwardOnSecurityPricesMigrationTest < ActiveSupport::TestCase
  FRIDAY = Date.new(2026, 10, 30)

  setup do
    @security = Security.create!(ticker: "BACKFILL", name: "Backfill")
  end

  test "marks provisional rows, across batches" do
    rows = (0..2).map { |day| price(FRIDAY + day.days, 100, provisional: true) }
    migration = BackfillCarriedForwardOnSecurityPrices.new
    migration.stubs(:batch_size).returns(1)
    updates = 0
    migration.define_singleton_method(:exec_update) { |*args| updates += 1; super(*args) }

    ActiveRecord::Migration.suppress_messages { migration.up }

    assert_equal [ true ] * 3, rows.map { |p| p.reload.carried_forward }
    # One update per row, then the empty one that ends the loop.
    assert_equal 4, updates
  end

  # A weekend row repeating Friday may be a pegged or crypto quote.
  test "leaves every non-provisional row, repeats included" do
    rows = [ price(FRIDAY, 100), price(FRIDAY + 1.day, 100), price(FRIDAY + 4.days, 100) ]

    run_migration

    assert_equal [ false ] * 3, rows.map { |p| p.reload.carried_forward }
  end

  test "can run twice" do
    provisional = price(FRIDAY, 100, provisional: true)

    run_migration
    run_migration

    assert provisional.reload.carried_forward
  end

  private
    def price(date, value, provisional: false)
      Security::Price.create!(security: @security, date: date, price: value, currency: "USD", provisional: provisional)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillCarriedForwardOnSecurityPrices.new.up
      end
    end
end
