# entries.excluded had a default but no NOT NULL, and a blank form value or
# `update!(excluded: "")` stored NULL. Ruby and the serializer read such a row
# as included, while most report, budget and transfer-matching queries filter
# on `excluded = false` and dropped it. The row showed in the transactions list
# and was missing from the totals. NULL becomes false, which is what the UI
# already showed.
#
# Batched outside a transaction so a large table is not locked in one
# statement. Only NULL rows are written, so it can run more than once. Each
# changed row gets a new updated_at, since report caches are keyed on it and
# these rows now count in the totals.
#
# The check is added NOT VALID once the rows are backfilled: new and updated
# rows are checked right away, and a row an old process wrote as NULL in the
# meantime is caught by the second pass. MakeEntriesExcludedNotNull validates
# the check and turns it into the column's NOT NULL.
class BackfillEntriesExcluded < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    backfill
    add_check_constraint :entries, "excluded IS NOT NULL",
      name: "chk_entries_excluded_not_null", validate: false, if_not_exists: true
    backfill
  end

  # The backfilled rows read as false before and are not set back to NULL.
  def down
    remove_check_constraint :entries, name: "chk_entries_excluded_not_null", if_exists: true
  end

  private
    def backfill
      loop do
        updated = exec_update(<<~SQL)
          UPDATE entries
          SET excluded = false, updated_at = CURRENT_TIMESTAMP
          WHERE id IN (SELECT id FROM entries WHERE excluded IS NULL LIMIT #{batch_size})
          AND excluded IS NULL
        SQL
        break if updated.zero? && !null_rows_remain?
      end
    end

    def batch_size
      10_000
    end

    # Uncached: the updates do not clear the query cache, so a cached answer
    # would keep the loop running.
    def null_rows_remain?
      connection.uncached do
        connection.select_value("SELECT 1 FROM entries WHERE excluded IS NULL LIMIT 1").present?
      end
    end
end
