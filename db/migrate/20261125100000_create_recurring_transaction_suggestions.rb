# One row per smart-fill or smart-configure request. The row is what the browser
# watches and what Stop addresses; the answer is stored so a reload of the
# dialog still shows it (and the Turbo Stream can carry only a frame with a src).
class CreateRecurringTransactionSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :recurring_transaction_suggestions, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Smart-fill starts from an entry, before a bill exists; smart-configure
      # from a series. Exactly one of the two identifies the suggestion's subject.
      t.references :recurring_transaction, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :cascade }
      t.boolean :income, default: false, null: false
      t.string :mode, null: false
      t.string :status, default: "pending", null: false
      t.jsonb :result
      t.string :error
      t.timestamps
    end

    add_check_constraint :recurring_transaction_suggestions,
                         "(recurring_transaction_id IS NOT NULL) <> (entry_id IS NOT NULL)",
                         name: "recurring_transaction_suggestions_one_subject"
    add_index :recurring_transaction_suggestions, [ :family_id, :created_at ]
  end
end
