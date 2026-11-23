class AddHistoryScopeIndexToRecurringOccurrences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :recurring_occurrences,
              [ :family_id, :historical, :status, :due_on ],
              name: "idx_recurring_occurrences_history_scope",
              algorithm: :concurrently
  end
end
