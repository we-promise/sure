class AddPlaidProfileToPlaidItems < ActiveRecord::Migration[8.1]
  def change
    add_column :plaid_items, :plaid_profile, :string, null: false, default: "default"
    add_index :plaid_items, [ :plaid_region, :plaid_profile ]
  end
end
