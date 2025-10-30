class RemoveLunchflowAccountIdFromAccounts < ActiveRecord::Migration[7.2]
  def change
    remove_reference :accounts, :lunchflow_account, foreign_key: true, type: :uuid
  end
end
