# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261114233000_add_updated_at_indexes_to_exchange_rates")

# CREATE INDEX CONCURRENTLY leaves an INVALID index behind when it's
# interrupted, and the migration (with `disable_ddl_transaction!`) stays
# pending, so the next run has to finish the job. These tests pin that the
# re-run rebuilds such a leftover instead of accepting it by name, and that the
# old to_currency index is only dropped once its replacement is valid.
class AddUpdatedAtIndexesToExchangeRatesMigrationTest < ActiveSupport::TestCase
  # CONCURRENTLY can't run inside the transaction each test is otherwise
  # wrapped in. Every test leaves the schema as the migration's `up` does.
  self.use_transactional_tests = false

  MIGRATION = AddUpdatedAtIndexesToExchangeRates

  teardown do
    run_migration(:up)
  end

  test "re-running over an invalid leftover index rebuilds it before dropping the old one" do
    run_migration(:down)
    assert valid_index?(MIGRATION::CURRENCY_INDEX), "precondition: the old to_currency index is back"

    # The state an interrupted run leaves: the replacement's name is in the
    # catalog, but PostgreSQL marks it invalid and never uses it.
    connection.execute(
      "CREATE INDEX #{MIGRATION::CURRENCY_UPDATED_AT_INDEX} ON exchange_rates (to_currency, updated_at)"
    )
    connection.execute(
      "UPDATE pg_index SET indisvalid = false " \
      "WHERE indexrelid = #{connection.quote(MIGRATION::CURRENCY_UPDATED_AT_INDEX)}::regclass"
    )
    assert_not valid_index?(MIGRATION::CURRENCY_UPDATED_AT_INDEX), "precondition: the leftover is invalid"

    run_migration(:up)

    assert valid_index?(MIGRATION::CURRENCY_UPDATED_AT_INDEX), "the invalid leftover was accepted instead of rebuilt"
    assert valid_index?(MIGRATION::UPDATED_AT_INDEX)
    assert_not index_named?(MIGRATION::CURRENCY_INDEX), "the old to_currency index should be gone"
  end

  test "down restores the to_currency index and removes the new ones" do
    run_migration(:down)

    assert valid_index?(MIGRATION::CURRENCY_INDEX)
    assert_not index_named?(MIGRATION::CURRENCY_UPDATED_AT_INDEX)
    assert_not index_named?(MIGRATION::UPDATED_AT_INDEX)
  end

  private
    def connection = ActiveRecord::Base.connection

    def valid_index?(name)
      connection.select_value(<<~SQL.squish) == true
        SELECT pg_index.indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = #{connection.quote(name)}
      SQL
    end

    def index_named?(name)
      connection.select_value("SELECT count(*) FROM pg_class WHERE relname = #{connection.quote(name)}").to_i.positive?
    end

    def run_migration(direction)
      ActiveRecord::Migration.suppress_messages { MIGRATION.new.public_send(direction) }
    end
end
