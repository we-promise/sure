class AddBillsFeedTokenToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :bills_feed_token, :string
    add_index :families, :bills_feed_token, unique: true
  end
end
