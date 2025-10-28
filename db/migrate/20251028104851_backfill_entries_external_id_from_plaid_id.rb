class BackfillEntriesExternalIdFromPlaidId < ActiveRecord::Migration[7.2]
  def up
    # Backfill external_id from plaid_id for entries that have plaid_id but no external_id
    # Set source to 'plaid' for these entries as well
    execute <<-SQL
      UPDATE entries
      SET external_id = plaid_id,
          source = 'plaid'
      WHERE plaid_id IS NOT NULL
        AND external_id IS NULL
    SQL
  end

  def down
    # Reverse the migration by clearing external_id and source for entries where they match plaid_id
    execute <<-SQL
      UPDATE entries
      SET external_id = NULL,
          source = NULL
      WHERE plaid_id IS NOT NULL
        AND external_id = plaid_id
        AND source = 'plaid'
    SQL
  end
end
