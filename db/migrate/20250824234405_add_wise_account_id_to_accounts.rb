class AddWiseAccountIdToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_reference :accounts, :wise_account, type: :uuid, foreign_key: true, index: true
  end
end