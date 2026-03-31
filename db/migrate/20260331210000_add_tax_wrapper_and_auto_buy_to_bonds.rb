class AddTaxWrapperAndAutoBuyToBonds < ActiveRecord::Migration[7.2]
  def change
    add_column :bonds, :tax_wrapper, :string, default: "none", null: false
    add_column :bonds, :auto_buy_new_issues, :boolean, default: false, null: false

    add_index :bonds, :tax_wrapper
  end
end
