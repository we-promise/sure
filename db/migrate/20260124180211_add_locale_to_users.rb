class AddLocaleToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :locale, :string, null: true, default: nil
    add_index :users, :locale
  end
end
