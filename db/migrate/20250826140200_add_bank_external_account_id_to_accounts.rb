class AddBankExternalAccountIdToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_reference :accounts, :bank_external_account, type: :uuid, foreign_key: true, index: true
  end
end
