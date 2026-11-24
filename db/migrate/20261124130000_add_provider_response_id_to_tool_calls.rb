class AddProviderResponseIdToToolCalls < ActiveRecord::Migration[8.1]
  # Idempotent: an instance that ran this under its earlier version
  # (20261123120000) already has the column.
  def change
    add_column :tool_calls, :provider_response_id, :string, if_not_exists: true
  end
end
