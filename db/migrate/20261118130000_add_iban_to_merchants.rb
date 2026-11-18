class AddIbanToMerchants < ActiveRecord::Migration[8.1]
  def up
    add_column :merchants, :iban, :string unless column_exists?(:merchants, :iban)
  end

  def down
    remove_column :merchants, :iban, if_exists: true
  end
end
