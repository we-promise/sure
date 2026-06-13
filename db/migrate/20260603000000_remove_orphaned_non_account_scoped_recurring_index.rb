class RemoveOrphanedNonAccountScopedRecurringIndex < ActiveRecord::Migration[7.2]
  def up
    # The migration AddAccountIdToRecurringTransactions (20260326112218) was
    # meant to remove the non-account-scoped unique index on
    #   (family_id, merchant_id, amount, currency)
    # but it referenced the index by the name "idx_recurring_txns_merchant".
    # The original CreateRecurringTransactions migration named it
    # "idx_recurring_txns_on_family_merchant_amount_currency", so the
    # remove_index call silently did nothing (if_exists: true) and the old
    # index survived.
    #
    # This orphaned index prevents two recurring transactions with the same
    # merchant/amount/currency from being created on different accounts,
    # because it lacks account_id in its column list.
    remove_index :recurring_transactions, name: "idx_recurring_txns_on_family_merchant_amount_currency", if_exists: true
  end

  def down
    add_index :recurring_transactions,
              [ :family_id, :merchant_id, :amount, :currency ],
              unique: true,
              name: "idx_recurring_txns_on_family_merchant_amount_currency"
  end
end
