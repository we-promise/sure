class AddProviderGenerationTransportRetries < ActiveRecord::Migration[8.1]
  def change
    add_column :provider_sync_generations, :transport_retry_count, :integer, null: false, default: 0
    add_check_constraint :provider_sync_generations,
      "transport_retry_count BETWEEN 0 AND 16 AND (stream = 'activities' OR transport_retry_count = 0)",
      name: "provider_generation_transport_retries"
  end
end
