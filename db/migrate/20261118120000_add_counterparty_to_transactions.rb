class AddCounterpartyToTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Only the last 4 characters of a counterparty's account identifiers are
    # kept, for display. The full IBAN is matched against the family's own
    # accounts at import and then dropped.
    add_column :transactions, :counterparty_iban_last4, :string
    add_column :transactions, :counterparty_reference_last4, :string
    add_reference :transactions, :counterparty_own_account, type: :uuid, index: { algorithm: :concurrently },
      foreign_key: { to_table: :accounts, on_delete: :nullify, validate: false }
  end
end
