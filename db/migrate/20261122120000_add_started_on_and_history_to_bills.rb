class AddStartedOnAndHistoryToBills < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :started_on, :date
    add_column :recurring_occurrences, :historical, :boolean, default: false, null: false

    add_index :recurring_occurrences,
              [ :family_id, :historical, :status, :due_on ],
              name: "idx_recurring_occurrences_history_scope"
  end
end
