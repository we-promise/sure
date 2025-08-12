class AddSimplefinAccountIdToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_reference :accounts, :simplefin_account, null: true, foreign_key: true, type: :uuid
  end
end
