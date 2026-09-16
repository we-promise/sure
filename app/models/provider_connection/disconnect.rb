require "digest"

# A local lifecycle operation, not an upstream consent revocation or an erase.
# Source evidence, financial history and encrypted migration archives survive.
class ProviderConnection::Disconnect
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end
  Form = Data.define(:connection, :accounts, :token)
  Result = Data.define(:connection, :replayed)
  PURPOSE = "provider-connection-disconnect/v1".freeze
  RECEIPT_KEY = "native_disconnect".freeze
  MAX_TOKEN_BYTES = 8.kilobytes
  MAX_RECEIPT_BYTES = 16.kilobytes

  def initialize(connection:, actor:)
    unless connection.is_a?(ProviderConnection) && connection.persisted?
      raise ArgumentError, "Expected a persisted provider connection"
    end
    @connection_id, @family_id, @provider_key, @actor_id =
      [ connection.id, connection.family_id, connection.provider_key, actor&.id ].map { |value| value&.dup&.freeze }
    @management = ProviderConnection::Management.new(connection: connection, actor: actor)
  end

  def form
    guarded do
      with_links do |links, context|
        # An old completion marker cannot be repurposed as a reconnect command.
        refuse! if context.connection.metadata.key?(RECEIPT_KEY)
        assert_idle!(context.connection, context.control)
        value = identity.merge("command_id" => SecureRandom.uuid,
          "binding_digest" => binding_digest(links, context))
        Form.new(connection: context.connection, accounts: links.accounts,
          token: verifier.generate(value, purpose: PURPOSE, expires_in: 30.minutes))
      end
    end
  end

  def call(token:)
    refuse! unless token.is_a?(String) && token.present? && token.bytesize <= MAX_TOKEN_BYTES
    guarded do
      # Completion is checked before form expiry and before discovering live
      # links: successful disconnection has already removed those links.
      replay = completed_result(token)
      next replay if replay

      expected = verifier.verified(token, purpose: PURPOSE)
      unless expected.is_a?(Hash) && expected.keys.sort == (identity.keys + %w[binding_digest command_id]).sort &&
          expected.slice(*identity.keys) == identity && uuid?(expected["command_id"])
        refuse!
      end
      with_links do |links, context|
        connection = context.connection
        refuse! if connection.metadata.key?(RECEIPT_KEY)
        refuse! unless expected["binding_digest"] == binding_digest(links, context)
        assert_idle!(connection, context.control)
        links.detach!
        connection.status = "disabled"
        connection.writer_epoch += 1
        receipt = identity.merge(
          "format" => PURPOSE, "command_id" => expected.fetch("command_id"),
          "token_digest" => Digest::SHA256.hexdigest(token),
          "binding_digest" => expected.fetch("binding_digest"),
          "disconnected_at" => Time.current.utc.iso8601(6),
          "result" => result_binding(connection, context)
        )
        receipt["signature"] = signing_keys.sign(receipt_message(receipt))
        connection.metadata = connection.metadata.merge(RECEIPT_KEY => receipt)
        connection.save!
        Result.new(connection: connection, replayed: false)
      end
    end
  end

  private
    def guarded
      Provider::AccountData::CredentialStore.with_connection_lock(connection_id: @connection_id) { yield }
    rescue ActiveRecord::LockWaitTimeout, Provider::AccountData::IncompletePage
      capture_failure(Busy)
      raise Busy, "Finish outstanding provider or account work before disconnecting", cause: nil
    rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError,
        Provider::AccountData::StaleWriter, Ingestion::IdentitySigningKeys::InvalidSignature,
        Ingestion::IdentitySigningKeys::InvalidConfiguration
      capture_failure(Conflict)
      refuse!
    end

    def with_links
      Links.new(connection_id: @connection_id, family_id: @family_id, actor_id: @actor_id).with_locked do |links|
        @management.with_lock { |context| yield links, context }
      end
    end

    def completed_result(token)
      @management.with_lock(allow_disabled: true) do |context|
        connection = context.connection
        next nil unless connection.disabled?
        receipt = connection.metadata[RECEIPT_KEY]
        keys = identity.keys + %w[format command_id token_digest binding_digest disconnected_at result signature]
        refuse! unless receipt.is_a?(Hash) && receipt.keys.sort == keys.sort &&
          receipt.slice(*identity.keys) == identity && receipt["format"] == PURPOSE &&
          receipt["token_digest"] == Digest::SHA256.hexdigest(token) && uuid?(receipt["command_id"])
        signing_keys.verify!(receipt.fetch("signature"), receipt_message(receipt.except("signature")))
        refuse! unless receipt["result"] == result_binding(connection, context)
        Links.new(connection_id: @connection_id, family_id: @family_id, actor_id: @actor_id).assert_detached!
        Result.new(connection: connection, replayed: true)
      end
    end

    def assert_idle!(connection, control)
      if connection.lease_owner || connection.lease_sync_id || connection.lease_expires_at || connection.syncs.incomplete.exists? ||
          connection.provider_sync_generations.unfinished.exists? || control&.lease_owner || control&.lease_expires_at
        raise Busy, "Provider work must finish before disconnection"
      end
      # Native ownership excludes ordinary legacy writers. Retained incomplete
      # work is still a blocker, not permission to discard its original intent.
      if control && Sync.where(syncable_type: control.legacy_type, syncable_id: control.legacy_id).incomplete.exists?
        raise Busy, "Legacy provider work must be resolved before disconnection"
      end
      if control && ProviderCredentialClaim.where(target_type: control.legacy_type, target_id: control.legacy_id,
          state: %w[prepared claiming claimed]).exists?
        raise Busy, "Outstanding credential claims must be resolved before disconnection"
      end
    end

    def binding_digest(links, context)
      Digest::SHA256.hexdigest(Provider::AccountData::MigrationValue.dump(
        "management" => context.binding, "links" => links.binding))
    end

    def result_binding(connection, context)
      { "status" => connection.status, "writer_epoch" => connection.writer_epoch,
        "credential_revision" => connection.credential_revision,
        "control" => context.binding.fetch("control"), "mapping" => context.binding.fetch("mapping") }
    end

    def identity
      { "connection_id" => @connection_id, "family_id" => @family_id,
        "provider_key" => @provider_key, "actor_id" => @actor_id }
    end

    def receipt_message(receipt)
      value = JSON.generate(receipt)
      refuse! if value.bytesize > MAX_RECEIPT_BYTES
      # PostgreSQL JSONB need not preserve hash insertion order.
      "#{PURPOSE}\0#{Provider::AccountData::MigrationValue.dump(receipt)}"
    end

    def signing_keys
      Ingestion::IdentitySigningKeys.configured
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(Provider::AccountData::LegacyWriterFence::UUID)
    end

    def refuse!
      raise Conflict, "Connection ownership or reviewed links changed; reload before disconnecting", cause: nil
    end

    def capture_failure(error_class)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", source: self.class.name,
        provider_key: @provider_key, family: Family.find_by(id: @family_id),
        message: "Native connection disconnection could not be completed",
        metadata: { provider_connection_id: @connection_id, error_class: error_class.name })
    rescue StandardError
      # Support diagnostics must not replace the original lifecycle refusal.
    end
end
