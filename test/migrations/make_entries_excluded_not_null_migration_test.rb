# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261126100000_backfill_entries_excluded")
require Rails.root.join("db/migrate/20261126100100_make_entries_excluded_not_null")

class MakeEntriesExcludedNotNullMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Each test starts from the nullable column an installation has before both
  # migrations. DDL is transactional in Postgres, so the change is rolled back
  # with the rest of the test.
  setup do
    not_null.down
    backfill.down
    @null_entry = create_transaction(account: accounts(:depository), name: "Blank form value")
    @excluded_entry = create_transaction(account: accounts(:depository), name: "Excluded", excluded: true)
    @null_entry.update_columns(updated_at: 1.year.ago)
    connection.execute(Entry.sanitize_sql_array([ "UPDATE entries SET excluded = NULL WHERE id = ?", @null_entry.id ]))
  end

  test "a NULL excluded becomes false and the column refuses NULL" do
    backfill.up
    not_null.up

    assert_equal false, stored_excluded(@null_entry)
    assert_equal true, stored_excluded(@excluded_entry)
    assert_not entries_column.null
    assert_not check_constraint_exists?
  end

  # Report caches are keyed on the newest entries.updated_at, and the totals
  # of a backfilled row change.
  test "the backfill touches only the rows it changes" do
    excluded_updated_at = @excluded_entry.reload.updated_at

    backfill.up

    assert_operator @null_entry.reload.updated_at, :>, 1.minute.ago
    assert_equal excluded_updated_at, @excluded_entry.reload.updated_at
  end

  test "the backfill can run again" do
    backfill.up
    backfill.up
    not_null.up

    assert_equal false, stored_excluded(@null_entry)
  end

  test "the check added not valid already refuses a NULL" do
    backfill.up

    assert check_constraint_exists?
    assert_raises(ActiveRecord::StatementInvalid) { write_null(@excluded_entry) }
  end

  test "rolling back both leaves the column nullable again" do
    backfill.up
    not_null.up
    not_null.down
    backfill.down

    assert entries_column.null
    assert_not check_constraint_exists?
    write_null(@excluded_entry)
    assert_nil stored_excluded(@excluded_entry)
  end

  private
    def backfill
      @backfill ||= BackfillEntriesExcluded.new.tap { |m| m.verbose = false }
    end

    def not_null
      @not_null ||= MakeEntriesExcludedNotNull.new.tap { |m| m.verbose = false }
    end

    def connection
      ActiveRecord::Base.connection
    end

    def stored_excluded(entry)
      connection.select_value(Entry.sanitize_sql_array([ "SELECT excluded FROM entries WHERE id = ?", entry.id ]))
    end

    # A savepoint, so a refused UPDATE leaves the test's transaction usable.
    def write_null(entry)
      Entry.transaction(requires_new: true) do
        connection.execute(Entry.sanitize_sql_array([ "UPDATE entries SET excluded = NULL WHERE id = ?", entry.id ]))
      end
    end

    def entries_column
      connection.columns(:entries).find { |column| column.name == "excluded" }
    end

    def check_constraint_exists?
      connection.check_constraints(:entries).any? { |constraint| constraint.name == "chk_entries_excluded_not_null" }
    end
end
