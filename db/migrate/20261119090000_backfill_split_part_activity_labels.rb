# Entry#split! used to create each part without the parent's investment
# activity label, so a split Dividend or Interest left the investment totals
# and a split sweep or transfer counted as income or spending. Give those
# unlabelled parts their parent's label, unless the user locked the part's
# label.
class BackfillSplitPartActivityLabels < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE transactions
      SET investment_activity_label = parent_transactions.investment_activity_label
      FROM entries
      JOIN entries parent_entries ON parent_entries.id = entries.parent_entry_id
        AND parent_entries.entryable_type = 'Transaction'
      JOIN transactions parent_transactions ON parent_transactions.id = parent_entries.entryable_id
      WHERE entries.entryable_type = 'Transaction'
        AND entries.entryable_id = transactions.id
        AND transactions.investment_activity_label IS NULL
        AND parent_transactions.investment_activity_label IS NOT NULL
        AND NOT (COALESCE(transactions.locked_attributes, '{}'::jsonb) ? 'investment_activity_label')
    SQL
  end

  # The parts' missing labels are not worth restoring.
  def down
  end
end
