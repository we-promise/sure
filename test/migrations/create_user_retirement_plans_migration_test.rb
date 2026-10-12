# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150100_create_user_retirement_plans")

# The migration owns the retirement_plans table: its columns, its unique user
# index, its foreign key to users and three check constraints. `down` must drop
# that table and nothing else, `up` must build it again as it was, and `up` must
# not quietly adopt a table it did not create -- a rollback would then drop that
# table and every saved plan with it. The schema changes roll back with the
# test's transaction.
class CreateUserRetirementPlansMigrationTest < ActiveSupport::TestCase
  TABLE = "retirement_plans"
  COLUMNS = %w[
    id user_id safe_withdrawal_rate expected_annual_return savings_rate retirement_date created_at updated_at
  ].freeze
  CONSTRAINTS = %w[
    chk_retirement_plans_expected_annual_return
    chk_retirement_plans_safe_withdrawal_rate
    chk_retirement_plans_savings_rate
  ].freeze

  # Later migrations point other tables at this one; their foreign keys would
  # block the drop. They are not this migration's to keep, so they are removed
  # first and come back with the test's transaction.
  setup { remove_dependent_foreign_keys }

  test "down then up restores the table, its index, its foreign key and its constraints" do
    before = shape

    migrate(:down)
    migrate(:up)

    assert_equal before, shape
    assert_equal [ "numeric(5,4)", BigDecimal("0.04"), false ], before[:columns]["safe_withdrawal_rate"]
    assert_equal [ "numeric(6,4)", BigDecimal("0.05"), false ], before[:columns]["expected_annual_return"]
    assert_equal [ [ "index_retirement_plans_on_user_id", [ "user_id" ], true ] ], before[:indexes]
    assert_equal [ [ "user_id", "users", :cascade ] ], before[:foreign_keys]
    assert_equal CONSTRAINTS, before[:constraints].keys
    assert_equal %w[0 1], before[:constraints]["chk_retirement_plans_safe_withdrawal_rate"]
    assert_equal %w[-1 1], before[:constraints]["chk_retirement_plans_expected_annual_return"]
  end

  test "down removes exactly the table that up adds" do
    tables_up = connection.tables

    migrate(:down)
    tables_down = connection.tables

    migrate(:up)

    assert_equal [ TABLE ], tables_up - tables_down
    assert_empty tables_down - tables_up
    assert_equal tables_up.sort, connection.tables.sort
  end

  test "up refuses a table it did not create rather than adopting it" do
    before = shape

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) { migrate(:up) }
    end

    assert_match(/DuplicateTable: ERROR:  relation "#{TABLE}" already exists/, error.message)
    assert_equal before, shape
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { CreateUserRetirementPlans.new.migrate(direction) }
    end

    def remove_dependent_foreign_keys
      connection.select_rows(<<~SQL).each { |table, name| connection.remove_foreign_key(table, name: name) }
        SELECT conrelid::regclass::text, conname FROM pg_constraint
        WHERE contype = 'f' AND confrelid = #{connection.quote(TABLE)}::regclass AND conrelid <> confrelid
      SQL
    end

    # What this migration declares, read back from the catalog. Columns later
    # migrations add to the table are left out: dropping the table takes them
    # too, and putting them back is those migrations' job.
    def shape
      return nil unless connection.table_exists?(TABLE)

      columns = connection.columns(TABLE).select { |c| COLUMNS.include?(c.name) }
      {
        columns: columns.to_h { |c| [ c.name, [ c.sql_type, c.default || c.default_function, c.null ] ] }.sort.to_h,
        indexes: connection.indexes(TABLE).select { |i| (i.columns - COLUMNS).empty? }
                           .map { |i| [ i.name, i.columns, i.unique ] }.sort,
        foreign_keys: connection.foreign_keys(TABLE).select { |k| COLUMNS.include?(k.column) }
                                .map { |k| [ k.column, k.to_table, k.on_delete ] }.sort,
        constraints: CONSTRAINTS.index_with { |name| constraint_literals(name) }.compact
      }
    end

    # The literals a check constraint compares against, in order. Compared
    # rather than the rendered predicate: a constraint loaded from schema.rb and
    # one created by `add_check_constraint` print the same check with different
    # casts.
    def constraint_literals(name)
      definition = connection.select_value(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " \
        "WHERE conname = #{connection.quote(name)} AND conrelid = #{connection.quote(TABLE)}::regclass"
      )
      definition&.scan(/'([^']*)'|\b(\d+(?:\.\d+)?)\b/)&.map { |quoted, number| quoted || number }
    end
end
