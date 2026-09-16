# Shared admission for native lifecycle commands. Migration provenance remains
# authoritative after the old item is retired; its absence is not a new connection.
class ProviderConnection::Management
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end
  Context = Data.define(:connection, :actor, :control, :mapping) do
    def binding
      { "connection_id" => connection.id, "family_id" => connection.family_id,
        "provider_key" => connection.provider_key, "actor_id" => actor.id,
        "lock_version" => connection.lock_version, "credential_revision" => connection.credential_revision,
        "writer_epoch" => connection.writer_epoch,
        "control" => control&.attributes&.slice("id", "family_id", "provider_key", "legacy_type", "legacy_id", "state", "writer_epoch", "provider_connection_id"),
        "mapping" => mapping&.attributes&.slice("id", "family_id", "legacy_type", "legacy_id", "provider_connection_id") }
    end
  end

  def initialize(connection:, actor:)
    unless connection.is_a?(ProviderConnection) && connection.persisted?
      raise ArgumentError, "Expected a persisted provider connection"
    end
    @connection_id, @family_id, @provider_key, @actor_id =
      [ connection.id, connection.family_id, connection.provider_key, actor&.id ].map { |value| value&.dup&.freeze }
  end

  # Disabled admission is only for verifying an already committed lifecycle
  # receipt. Ordinary editors/setup must continue to use the default.
  def with_lock(allow_disabled: false)
    ApplicationRecord.uncached do
      ApplicationRecord.transaction(requires_new: true) do
        connection = ProviderConnection.where(id: @connection_id, family_id: @family_id, provider_key: @provider_key)
          .lock("FOR UPDATE NOWAIT").first!
        actor = User.where(id: @actor_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first
        refuse! unless actor&.active? && actor.admin? && (allow_disabled || !connection.disabled?) && !connection.scheduled_for_deletion?
        Provider::AccountData::Registry.fetch(connection.provider_key)
        control = ProviderMigrationControl.where(provider_connection_id: connection.id).lock("FOR UPDATE NOWAIT").first
        mapping = nil
        if control
          refuse! unless control.family_id == @family_id && control.provider_key == @provider_key && control.native_owned?
          mappings = control.provider_migration_mappings.where(role: "connection").order(:id).limit(2).lock("FOR UPDATE NOWAIT").to_a
          mapping = mappings.first
          unless mappings.one? && mapping.family_id == @family_id && mapping.provider_connection_id == connection.id &&
              mapping.legacy_type == control.legacy_type && mapping.legacy_id == control.legacy_id &&
              mapping.external_account_id.nil? && mapping.provider_authorization_id.nil?
            refuse!
          end
        elsif connection.metadata.key?("legacy_type") || connection.metadata.key?("legacy_id") ||
            ProviderMigrationMapping.where(provider_connection_id: connection.id).exists?
          refuse!
        end
        yield Context.new(connection: connection, actor: actor, control: control, mapping: mapping)
      end
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError
    refuse!
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Provider ownership is being changed; retry after it finishes", cause: nil
  end

  private
    def refuse!
      raise Conflict, "Provider management ownership changed; reload before continuing", cause: nil
    end
end
