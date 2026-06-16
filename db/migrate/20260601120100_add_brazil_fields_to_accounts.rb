class AddBrazilFieldsToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_reference :accounts, :brazil_bank, type: :uuid, foreign_key: { to_table: :brazil_banks }
    add_column :accounts, :brazil_account_kind, :string
    add_index :accounts, :brazil_account_kind
  end
end
