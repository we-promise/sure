class MigratePublicOauthApplicationsToMcpScope < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE oauth_applications
      SET scopes = 'mcp:read_write', updated_at = CURRENT_TIMESTAMP
      WHERE confidential = FALSE AND scopes = 'read_write'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Migrated applications cannot be distinguished from new MCP applications."
  end
end
