module ProviderConnectionsHelper
  def native_disconnect_available?(connection)
    Provider::AccountData::Registry.fetch(connection.provider_key)
    true
  rescue Provider::AccountData::UnsupportedCapability
    false
  end

  def native_account_setup_available?(connection)
    Provider::AccountData::Registry.fetch(connection.provider_key).account_setup_types.any?
  rescue Provider::AccountData::UnsupportedCapability
    false
  end
end
