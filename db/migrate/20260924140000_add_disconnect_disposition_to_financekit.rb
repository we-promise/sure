class AddDisconnectDispositionToFinancekit < ActiveRecord::Migration[8.1]
  def change
    # Whether FinanceKit created this canonical account or was linked to one the
    # family already had. A discard may destroy the first but only empties the
    # second, which carries history FinanceKit never supplied. Nullable because
    # lineages mapped before this column cannot be classified after the fact;
    # NULL reads as "linked", the choice that cannot delete a user's own account.
    add_column :financekit_account_lineages, :account_origin, :string
    add_check_constraint :financekit_account_lineages,
      "account_origin IS NULL OR account_origin IN ('created', 'linked')",
      name: "financekit_lineage_account_origin"

    # A discard is accepted synchronously and carried out in the background, so
    # the intent has to outlive the request and the job. The sweep in
    # FinancekitInboxJob finishes any purge whose job was lost.
    add_column :financekit_items, :purge_requested_at, :datetime
    add_column :financekit_items, :purge_completed_at, :datetime
    add_index :financekit_items, :purge_requested_at,
      where: "purge_completed_at IS NULL", name: "financekit_items_pending_purge"
  end
end
