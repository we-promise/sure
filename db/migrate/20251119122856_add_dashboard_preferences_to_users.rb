class AddDashboardPreferencesToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :dashboard_preferences, :jsonb, default: {}, null: false
    add_index :users, :dashboard_preferences, using: :gin
  end
end
