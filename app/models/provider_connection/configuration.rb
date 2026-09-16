# Native settings never write back into a retained legacy snapshot. A signed
# form selects its original connection/revision, and replacement joins the same
# credential lock as remote refresh before taking short database locks.
class ProviderConnection::Configuration
  class Conflict < Provider::AccountData::StaleWriter; end
  Form = Data.define(:connection, :token, :credential_fields)
  PURPOSE = "provider-connection-configuration/v1".freeze
  MAX_TOKEN_BYTES = 8.kilobytes
  MAX_SECRET_BYTES = 16.kilobytes

  def initialize(connection:, actor:)
    unless connection.is_a?(ProviderConnection) && connection.persisted?
      raise ArgumentError, "Expected a persisted provider connection"
    end
    @connection_id, @family_id, @provider_key, @actor_id =
      [ connection.id, connection.family_id, connection.provider_key, actor&.id ].map { |value| value&.dup&.freeze }
    @management = ProviderConnection::Management.new(connection: connection, actor: actor)
  end

  def form
    with_locked do |connection, control, mapping|
      Form.new(connection: connection,
        token: verifier.generate(binding(connection, control, mapping), purpose: PURPOSE, expires_in: 30.minutes),
        credential_fields: fields(connection).freeze)
    end
  end

  def update!(token:, attributes:)
    refuse! unless token.is_a?(String) && token.bytesize <= MAX_TOKEN_BYTES
    expected = verifier.verified(token, purpose: PURPOSE)
    refuse! unless expected.is_a?(Hash)
    Provider::AccountData::CredentialStore.with_connection_lock(connection_id: @connection_id) do
      with_locked do |connection, control, mapping|
        refuse! unless expected == binding(connection, control, mapping)
        values = validate_attributes!(attributes, connection)
        # A pending Sync can already own a captured page or child calculation.
        # Reconfiguration does not cancel it or silently adopt its old input.
        if connection.lease_owner || connection.lease_sync_id || connection.syncs.incomplete.exists?
          raise Provider::AccountData::CredentialStore::Busy, "Finish provider work before changing its configuration"
        end
        connection.name = values.fetch("name", connection.name)
        connection.sync_start_date = values.fetch("sync_start_date", connection.sync_start_date)
        secrets = values.slice(*fields(connection)).reject { |_, value| value.blank? }
        if secrets.any?
          unless connection.credential_state.empty? && !connection.provider_authorizations.exists?
            raise Conflict, "Credential replacement requires its authorization flow"
          end
          replacement = connection.credentials.merge(secrets)
          if replacement != connection.credentials
            connection.credentials = replacement
            connection.status = "good"
          end
        end
        if connection.changed?
          connection.writer_epoch += 1
          connection.save!
        end
        connection
      end
    end
  end

  private
    def with_locked
      @management.with_lock do |context|
        yield context.connection, context.control, context.mapping
      end
    rescue ProviderConnection::Management::Conflict
      refuse!
    rescue ProviderConnection::Management::Busy
      raise Provider::AccountData::CredentialStore::Busy, "Provider configuration is being changed", cause: nil
    end

    def fields(connection)
      adapter = Provider::AccountData::Registry.fetch(connection.provider_key)
      names = adapter.editable_connection_credentials
      definition = adapter.definition
      allowed = definition.fields.select { |field| field[:secret] && %w[string text].include?(field[:type]) }.map { |field| field[:name] }
      unless names.is_a?(Array) && names.uniq == names && (names - allowed).empty? && (names.empty? || definition.credential_scope == "connection")
        raise Provider::AccountData::UnsupportedCapability, "Provider credential editing contract is invalid"
      end
      names.dup
    end

    def binding(connection, control, mapping)
      { "connection_id" => connection.id, "family_id" => @family_id, "provider_key" => @provider_key, "actor_id" => @actor_id,
        "lock_version" => connection.lock_version, "credential_revision" => connection.credential_revision,
        "writer_epoch" => connection.writer_epoch,
        "control" => control&.attributes&.slice("id", "family_id", "provider_key", "legacy_type", "legacy_id", "state", "writer_epoch", "provider_connection_id"),
        "mapping" => mapping&.attributes&.slice("id", "family_id", "legacy_type", "legacy_id", "provider_connection_id"),
        "credential_fields" => fields(connection) }
    end

    def validate_attributes!(attributes, connection)
      raise ArgumentError, "Configuration must be an object" unless attributes.is_a?(Hash)
      values = attributes.stringify_keys
      secret_fields = fields(connection)
      raise ArgumentError, "Unsupported configuration field" unless (values.keys - %w[name sync_start_date] - secret_fields).empty?
      if values.key?("name") && !(values["name"].is_a?(String) && values["name"].present? && values["name"].bytesize <= 255)
        raise ArgumentError, "Connection name is invalid"
      end
      if values.key?("sync_start_date")
        date = values["sync_start_date"]
        raise ArgumentError, "History date is invalid" unless date.is_a?(String)
        values["sync_start_date"] = if date.blank?
          nil
        else
          raise ArgumentError, "History date is invalid" unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          Date.iso8601(date)
        end
      end
      values.slice(*secret_fields).each_value do |value|
        unless value.is_a?(String) && value.bytesize <= MAX_SECRET_BYTES && !value.match?(/[\r\n\0]/)
          raise ArgumentError, "Credential value is invalid"
        end
      end
      values
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def refuse!
      raise Conflict, "Provider configuration owner or form changed; reload before updating", cause: nil
    end
end
