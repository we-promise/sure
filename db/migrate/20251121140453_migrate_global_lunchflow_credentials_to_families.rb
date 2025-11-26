class MigrateGlobalLunchflowCredentialsToFamilies < ActiveRecord::Migration[7.2]
  def up
    # Get global Lunchflow credentials from settings table
    global_api_key = execute(<<~SQL).to_a.first&.dig("value")
      SELECT value FROM settings WHERE var = 'lunchflow_api_key' LIMIT 1
    SQL

    global_base_url = execute(<<~SQL).to_a.first&.dig("value")
      SELECT value FROM settings WHERE var = 'lunchflow_base_url' LIMIT 1
    SQL

    # Only proceed if global API key exists
    if global_api_key.present?
      say "Found global Lunchflow API key, migrating to family-specific configuration..."

      # Update lunchflow_items that don't have credentials yet
      rows_updated = execute(<<~SQL).cmd_tuples
        UPDATE lunchflow_items
        SET api_key = #{connection.quote(global_api_key)},
            base_url = #{connection.quote(global_base_url)}
        WHERE api_key IS NULL
      SQL

      say "Migrated credentials to #{rows_updated} lunchflow_items"

      # Remove global settings as they're no longer used
      execute("DELETE FROM settings WHERE var = 'lunchflow_api_key'")
      execute("DELETE FROM settings WHERE var = 'lunchflow_base_url'")

      say "Removed global Lunchflow settings (now per-family)"
    else
      say "No global Lunchflow credentials found, skipping migration"
    end
  end

  def down
    # This migration is not reversible because we don't know which families
    # had credentials before vs. which received them from global settings
    say "This migration cannot be reversed - credentials are now per-family"
  end
end
