class AddProviderMigrationPreparationState < ActiveRecord::Migration[8.1]
  def change
    add_column :provider_migration_controls, :preparation_state, :text
    add_column :provider_migration_mappings, :preparation_state, :text
  end
end
