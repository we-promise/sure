class AddProviderResponseIdToToolCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :tool_calls, :provider_response_id, :string
  end
end
