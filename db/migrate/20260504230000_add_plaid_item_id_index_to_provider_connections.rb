class AddPlaidItemIdIndexToProviderConnections < ActiveRecord::Migration[7.2]
  # Webhook handlers look up Provider::Connection by metadata.plaid_item_id on
  # every Plaid webhook delivery. Without an index this is a sequential scan.
  # Partial expression index keeps the index small (only Plaid rows have a
  # plaid_item_id key) while making the lookup O(log N).
  def change
    add_index :provider_connections,
              "(metadata->>'plaid_item_id')",
              name:  "index_provider_connections_on_plaid_item_id",
              where: "(metadata ? 'plaid_item_id')"
  end
end
