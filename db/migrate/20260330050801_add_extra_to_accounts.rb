class AddExtraToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :extra, :jsonb, default: {}, null: false
    add_index :accounts, :extra, using: :gin
  end
end
