# Registry entries come from adapter declarations in the application source tree.
# Resolve those trusted file names on access so Rails reloads never retain stale
# classes; database/request keys only look up the resulting allowlist.
class Provider::AccountData::Registry
  def self.keys
    adapters.select { |_, adapter| adapter.native_ready? }.keys
  end

  def self.fetch(key)
    adapter = declared_adapter(key)
    unless adapter&.native_ready?
      raise Provider::AccountData::UnsupportedCapability, "Account data adapter is not ready for native sync"
    end
    adapter
  end

  # Replay validates the trusted declaration even when activation is disabled.
  def self.declared_adapter(key)
    adapters[key] || raise(Provider::AccountData::UnsupportedCapability, "Unknown account data adapter")
  end

  def self.build(connection, observed_at:, sync: nil, request_grant: nil)
    adapter = fetch(connection.provider_key)
    grant = request_grant || Provider::AccountData::RequestGrant.new(connection)
    grant.assert_connection!(connection)
    built = grant.with_adapter_snapshot(adapter: adapter, observed_at: observed_at, sync: sync) do |locked_connection, context|
      adapter.build(
        credentials: locked_connection.credentials, settings: locked_connection.settings,
        context: context
      )
    end
    unless built.is_a?(Provider::AccountData::Adapter)
      raise Provider::AccountData::InvalidResponse, "Factory did not construct an account data adapter"
    end
    built.bind_request_grant!(grant)
  end

  def self.adapters
    Dir[Rails.root.join("app/models/provider/account_data/*.rb")].sort.each_with_object({}) do |path, registry|
      name = File.basename(path, ".rb").camelize
      candidate = "Provider::AccountData::#{name}".constantize
      next unless candidate.is_a?(Class) && candidate < Provider::AccountData::Adapter
      key = candidate.definition.key
      raise ArgumentError, "Duplicate account data provider declaration" if registry.key?(key)
      registry[key] = candidate
    end
  end
  private_class_method :adapters
end
