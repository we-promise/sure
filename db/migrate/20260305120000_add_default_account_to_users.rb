class AddDefaultAccountToUsers < ActiveRecord::Migration[7.2]
  def change
    add_reference :users, :default_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true
  end
end
