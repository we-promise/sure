# Migration bridge to the existing deployment settings UI. Only explicit, trusted
# bindings may read application secrets. Factories receive their selected values;
# neither provider payloads nor connection metadata name settings or ENV keys.
class Provider::AccountData::ApplicationCredentials
  def self.build(connection)
    if connection.provider_key == "snaptrade"
      configured = Rails.configuration.x.snaptrade
      values = { oauth_client_id: configured&.oauth_client_id, oauth_client_secret: configured&.oauth_client_secret }
      unless values.values.all? { |value| value.is_a?(String) && value.present? }
        raise Provider::AccountData::InvalidResponse, "SnapTrade application credentials are not configured"
      end
      return values
    end
    unless connection.provider_key == "plaid"
      raise Provider::AccountData::UnsupportedCapability, "No application credential binding for this integration"
    end
    binding = Provider::AccountData::Plaid::DeploymentBinding
    application = binding.configured_application(region: connection.region)
    unless connection.environment == application.fetch(:environment)
      raise Provider::AccountData::InvalidResponse, "Plaid application and connection environments differ"
    end
    binding.verify_connection!(connection: connection, application: application)
    application
  rescue Provider::AccountData::MigrationCopier::Conflict
    raise Provider::AccountData::InvalidResponse, "Plaid application credentials are not configured for this region", cause: nil
  end

  def self.fallback(connection)
    unless connection.provider_key == "indexa_capital"
      raise Provider::AccountData::UnsupportedCapability, "No deployment credential fallback for this integration"
    end
    { api_token: ENV["INDEXA_API_TOKEN"].presence }.compact
  end
end
