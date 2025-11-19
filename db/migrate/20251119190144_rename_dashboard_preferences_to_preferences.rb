class RenameDashboardPreferencesToPreferences < ActiveRecord::Migration[7.2]
  def change
    # The index is automatically renamed by PostgreSQL when we rename the column
    rename_column :users, :dashboard_preferences, :preferences
  end
end
