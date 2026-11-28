# Validates the check BackfillEntriesExcluded added as NOT VALID, in its own
# migration so the full-table scan runs after that lock has been released;
# VALIDATE CONSTRAINT only takes SHARE UPDATE EXCLUSIVE. PostgreSQL then uses
# the validated check to set NOT NULL without scanning the table again, and the
# check is dropped as redundant.
class MakeEntriesExcludedNotNull < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :entries, name: "chk_entries_excluded_not_null"
    change_column_null :entries, :excluded, false
    remove_check_constraint :entries, name: "chk_entries_excluded_not_null"
  end

  # Back to the NOT VALID check the previous migration leaves; rolling that one
  # back removes it.
  def down
    change_column_null :entries, :excluded, true
    add_check_constraint :entries, "excluded IS NOT NULL", name: "chk_entries_excluded_not_null", validate: false
  end
end
