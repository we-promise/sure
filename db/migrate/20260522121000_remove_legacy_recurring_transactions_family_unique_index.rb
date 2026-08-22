class RemoveLegacyRecurringTransactionsFamilyUniqueIndex < ActiveRecord::Migration[7.2]
  def change
    remove_index :recurring_transactions,
      name: "idx_recurring_txns_on_family_merchant_amount_currency",
      if_exists: true
  end
end
