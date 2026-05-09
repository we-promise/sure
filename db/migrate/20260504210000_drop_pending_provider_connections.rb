# Drops any Provider::Connection rows in :pending status. Pending was
# previously used to hold OAuth-flow state mid-flight; flows now persist
# in session and only create a connection when credentials are real, so
# any :pending row is an abandoned flow and safe to delete.
class DropPendingProviderConnections < ActiveRecord::Migration[7.2]
  def up
    execute "DELETE FROM provider_connections WHERE status = 'pending'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
