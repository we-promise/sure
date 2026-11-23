class AddStartedOnAndHistoryToBills < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :started_on, :date
    add_column :recurring_occurrences, :historical, :boolean, default: false, null: false
  end
end
