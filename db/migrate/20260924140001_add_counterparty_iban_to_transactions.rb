class AddCounterpartyIbanToTransactions < ActiveRecord::Migration[7.2]
  def change
    # Dedicated, deterministically encrypted columns for a transaction
    # counterparty's own bank account identifiers (see Transaction and
    # EnableBankingEntry::Processor#extra) -- unlike the rest of the
    # provider metadata this data used to travel alongside in the plain
    # jsonb `extra` column, a third party's bank account number must not
    # sit at rest in plaintext. No uniqueness constraint: unlike
    # accounts.iban/merchants.iban, many transactions legitimately share
    # the same counterparty.
    add_column :transactions, :counterparty_iban, :string
    add_column :transactions, :counterparty_account_id, :string
  end
end
