class BackfillEntryProtectionFlags < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    # Backfill import_locked for entries that came from CSV/manual imports
    # These entries have import_id set but typically no external_id or source
    say_with_time "Marking CSV-imported entries as import_locked" do
      execute <<-SQL.squish
        UPDATE entries
        SET import_locked = true
        WHERE import_id IS NOT NULL
          AND import_locked = false
      SQL
    end

    # Backfill user_modified for entries where user has manually edited fields
    # These entries have non-empty locked_attributes (set when user edits)
    say_with_time "Marking user-edited entries as user_modified" do
      execute <<-SQL.squish
        UPDATE entries
        SET user_modified = true
        WHERE locked_attributes != '{}'::jsonb
          AND locked_attributes IS NOT NULL
          AND user_modified = false
      SQL
    end
  end

  def down
    # Reversible but generally not needed
    execute "UPDATE entries SET import_locked = false WHERE import_locked = true"
    execute "UPDATE entries SET user_modified = false WHERE user_modified = true"
  end
end
