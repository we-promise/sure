class CreateSavingsGoalAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_goal_accounts, id: :uuid do |t|
      t.references :savings_goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.timestamps
    end

    add_index :savings_goal_accounts,
              [ :savings_goal_id, :account_id ],
              unique: true,
              name: "index_savings_goal_accounts_on_goal_and_account"
  end
end
