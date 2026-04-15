# frozen_string_literal: true

# Superseded by idx_recurring_txns_acct_merchant / idx_recurring_txns_acct_name (account-scoped).
# Leaving the old index caused RecordNotUnique when the same merchant+amount existed on two accounts.
class RemoveObsoleteRecurringTransactionsFamilyMerchantIndex < ActiveRecord::Migration[7.2]
  def up
    remove_index :recurring_transactions,
      name: "idx_recurring_txns_on_family_merchant_amount_currency",
      if_exists: true
  end

  def down
    add_index :recurring_transactions,
      [ :family_id, :merchant_id, :amount, :currency ],
      unique: true,
      name: "idx_recurring_txns_on_family_merchant_amount_currency"
  end
end
