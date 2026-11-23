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

# A refresh can commit a real quote between the backfill's subquery and its
# update. Real connections and commits, so this cannot run in a transaction.
class BackfillCarriedForwardOnSecurityPricesRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @security = Security.create!(ticker: "BACKFILLRACE", name: "Backfill race")
    @row = Security::Price.create!(security: @security, date: Date.new(2026, 10, 30), price: 100, currency: "USD", provisional: true)
  end

  teardown do
    Security::Price.where(security_id: @security.id).delete_all
    @security.delete
  end

  test "skips a row a refresh made real while the update waited for it" do
    refresh = ActiveRecord::Base.connection_pool.checkout
    refresh.begin_db_transaction
    refresh.exec_update("UPDATE security_prices SET provisional = false, price = 101 WHERE id = #{refresh.quote(@row.id)}")

    backfill = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Migration.suppress_messages { BackfillCarriedForwardOnSecurityPrices.new.up }
      end
    end

    assert wait_for_blocked_update, "the backfill must be waiting on the refresh's row lock"
    refresh.commit_db_transaction
    backfill.join(10)

    @row.reload
    assert_equal [ false, false ], [ @row.provisional, @row.carried_forward ]
  ensure
    refresh&.rollback_db_transaction if refresh&.transaction_open?
    ActiveRecord::Base.connection_pool.checkin(refresh) if refresh
  end

  private
    def wait_for_blocked_update
      50.times do
        # Uncached: a cached first answer would be repeated on every poll.
        waiting = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value(<<~SQL)
            SELECT count(*) FROM pg_stat_activity
            WHERE wait_event_type = 'Lock' AND query LIKE '%SET carried_forward = true%'
          SQL
        end
        return true if waiting.to_i.positive?
        sleep 0.1
      end
      false
    end
end
