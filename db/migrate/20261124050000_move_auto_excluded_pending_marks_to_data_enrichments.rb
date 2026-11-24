# Stale pendings the sync excluded used to carry a flag in transactions.extra.
# Entry#auto_exclusion now reads a "sync" DataEnrichment instead, so carry the
# flag over to keep those entries re-activatable when they book.
class MoveAutoExcludedPendingMarksToDataEnrichments < ActiveRecord::Migration[8.1]
  MARK = "auto_excluded_stale_pending".freeze

  def up
    execute <<~SQL.squish
      INSERT INTO data_enrichments (enrichable_type, enrichable_id, source, attribute_name, value, metadata, created_at, updated_at)
      SELECT 'Entry', entries.id, 'sync', 'excluded', 'true'::jsonb,
             jsonb_build_object('reason', 'stale_pending', 'provider', entries.source, 'days', 8),
             entries.updated_at, entries.updated_at
      FROM entries
      JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'
      WHERE entries.excluded = TRUE AND transactions.extra -> '#{MARK}' = 'true'::jsonb
      ON CONFLICT (enrichable_id, enrichable_type, source, attribute_name)
      DO UPDATE SET value = EXCLUDED.value, metadata = EXCLUDED.metadata, updated_at = EXCLUDED.updated_at
    SQL

    execute "UPDATE transactions SET extra = extra - '#{MARK}' WHERE extra ? '#{MARK}'"
  end

  def down
    execute <<~SQL.squish
      UPDATE transactions SET extra = COALESCE(transactions.extra, '{}'::jsonb) || jsonb_build_object('#{MARK}', true)
      FROM entries
      JOIN data_enrichments ON data_enrichments.enrichable_type = 'Entry' AND data_enrichments.enrichable_id = entries.id
        AND data_enrichments.source = 'sync' AND data_enrichments.attribute_name = 'excluded'
      WHERE transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'
        AND entries.excluded = TRUE AND data_enrichments.metadata ->> 'reason' = 'stale_pending'
    SQL
  end
end
