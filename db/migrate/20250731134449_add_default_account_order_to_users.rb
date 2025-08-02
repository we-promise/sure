class AddDefaultAccountOrderToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :default_account_order, :string, default: "name_asc"
  end
end
