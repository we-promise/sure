# Two clicks can race the lookup-and-insert in both controllers. Serialising on
# the subject row covers ordinary requests; these partial indexes keep another
# writer from creating a second pending job even outside those controllers.
class AddPendingRecurringTransactionSuggestionIndexes < ActiveRecord::Migration[8.1]
  FILL_INDEX = "idx_recurring_suggestions_pending_fill".freeze
  CONFIGURE_INDEX = "idx_recurring_suggestions_pending_configure".freeze

  def up
    # Keep the oldest row in each pending identity: it is the one whose job was
    # queued first. Cleanup runs before the indexes make duplicates impossible.
    execute <<~SQL
      DELETE FROM recurring_transaction_suggestions AS victim
      USING recurring_transaction_suggestions AS keeper
      WHERE victim.status = 'pending'
        AND keeper.status = 'pending'
        AND victim.mode = 'fill'
        AND keeper.mode = 'fill'
        AND victim.entry_id IS NOT NULL
        AND victim.entry_id = keeper.entry_id
        AND victim.family_id = keeper.family_id
        AND victim.user_id = keeper.user_id
        AND victim.income = keeper.income
        AND (keeper.created_at, keeper.id) < (victim.created_at, victim.id)
    SQL

    execute <<~SQL
      DELETE FROM recurring_transaction_suggestions AS victim
      USING recurring_transaction_suggestions AS keeper
      WHERE victim.status = 'pending'
        AND keeper.status = 'pending'
        AND victim.mode = 'configure'
        AND keeper.mode = 'configure'
        AND victim.recurring_transaction_id IS NOT NULL
        AND victim.recurring_transaction_id = keeper.recurring_transaction_id
        AND victim.family_id = keeper.family_id
        AND victim.user_id = keeper.user_id
        AND (keeper.created_at, keeper.id) < (victim.created_at, victim.id)
    SQL

    add_index :recurring_transaction_suggestions,
              [ :family_id, :user_id, :entry_id, :income ],
              unique: true, where: "status = 'pending' AND mode = 'fill'", name: FILL_INDEX
    add_index :recurring_transaction_suggestions,
              [ :family_id, :user_id, :recurring_transaction_id ],
              unique: true, where: "status = 'pending' AND mode = 'configure'", name: CONFIGURE_INDEX
  end

  def down
    remove_index :recurring_transaction_suggestions, name: FILL_INDEX
    remove_index :recurring_transaction_suggestions, name: CONFIGURE_INDEX
  end
end
