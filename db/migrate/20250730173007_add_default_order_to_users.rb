class AddDefaultOrderToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :default_order, :string, default: "name_asc"
  end
end
