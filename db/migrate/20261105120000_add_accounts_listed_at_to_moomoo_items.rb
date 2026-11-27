class AddAccountsListedAtToMoomooItems < ActiveRecord::Migration[8.1]
  def change
    add_column :moomoo_items, :accounts_listed_at, :datetime
  end
end
