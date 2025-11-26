class AddPreferencesToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :preferences, :jsonb, default: {}, null: false
    add_index :users, :preferences, using: :gin
  end
end
