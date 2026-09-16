# Pins the canonical account Record and selected window/cursor passed to one
# ordinary request. Factory-retained history stays in RuntimeInputs; mutable
# routing and window configuration must still match when this page publishes.
class Provider::AccountData::RequestInputs
  EVIDENCE_KEY = "request_inputs"
  VERSION = 1
  FINGERPRINT_KEYS = %w[checkpoint configuration cursor record source_binding window].freeze
  EVIDENCE_KEYS = (FINGERPRINT_KEYS + %w[scope version]).sort.freeze

  def initialize(connection:, sync:, stream:, external_account: nil, record_builder:, history_metadata_keys: [])
    @connection, @sync, @stream, @external_account, @record_builder = connection, sync, stream, external_account, record_builder
    unless history_metadata_keys.is_a?(Array) && history_metadata_keys.uniq == history_metadata_keys &&
        history_metadata_keys.all? { |key| key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]*\z/) }
      raise ArgumentError, "History metadata keys must be declared field names"
    end
    @history_metadata_keys = history_metadata_keys.map { |key| key.dup.freeze }.freeze
    unless %w[accounts balances transactions holdings activities].include?(stream) &&
        (stream == "accounts") == external_account.nil? && sync.syncable_type == "ProviderConnection" && sync.syncable_id == connection.id &&
        (!external_account || (external_account.provider_connection_id == connection.id && external_account.family_id == connection.family_id))
      raise Provider::AccountData::StaleWriter, "Request inputs belong to another source"
    end
  end

  # Capture the exact objects that selected the initial stream window/cursor.
  # Admission checks these fingerprints instead of silently selecting new ones.
  def configuration
    fingerprint(configuration_values(connection, sync, external_account))
  end

  def checkpoint_fingerprint(checkpoint)
    if checkpoint && !(checkpoint.provider_connection_id == connection.id && checkpoint.family_id == connection.family_id &&
        checkpoint.external_account_id == external_account&.id && checkpoint.provider_authorization_id.nil? &&
        checkpoint.stream == stream && checkpoint.scope_key == scope_key)
      raise Provider::AccountData::StaleWriter, "Request checkpoint belongs to another scope"
    end
    fingerprint(checkpoint&.attributes)
  end

  # Called by RequestGrant's admission callback, after its full account lock plan.
  # No source cache write happens between constructing Record and retaining proof.
  def capture!(request_key:, configuration:, checkpoint:, window:, cursor:)
    require_transaction!
    binding = external_account ? resolver.capture_one(external_account) : {}
    if external_account && binding["publication"] != "ledger"
      raise Provider::AccountData::StaleWriter, "Account is no longer eligible for this source request"
    end
    external = current_external
    verify_selection!(configuration, checkpoint, external)
    record = external && @record_builder.call(external)
    selected_window = copy(window)
    selected_cursor = copy(cursor)
    evidence = copy("version" => VERSION, "scope" => scope(request_key),
      "configuration" => configuration, "checkpoint" => checkpoint,
      "record" => record_fingerprint(record), "source_binding" => fingerprint(binding),
      "window" => fingerprint(selected_window), "cursor" => fingerprint(selected_cursor))
    { binding: copy(binding), record: record, window: selected_window, cursor: selected_cursor, evidence: evidence }.freeze
  end

  # The outer publication transaction has already revalidated RequestGrant and
  # retains its locks. Check this proof before updating ExternalAccount or Entry.
  def verify!(batch:, evidence:)
    require_transaction!
    unless evidence.is_a?(Hash) && evidence.keys.sort == EVIDENCE_KEYS && evidence["version"] == VERSION &&
        evidence["scope"] == scope(batch.idempotency_key) && batch.provider_connection_id == connection.id &&
        batch.family_id == connection.family_id && batch.sync_id == sync.id && batch.stream == stream &&
        batch.external_account_id == external_account&.id && batch.scope_key == scope_key &&
        FINGERPRINT_KEYS.all? { |key| evidence[key].is_a?(String) && evidence[key].match?(/\A[0-9a-f]{64}\z/) } &&
        fingerprint(batch.source_binding) == evidence["source_binding"]
      raise Provider::AccountData::StaleWriter, "Response has no valid captured request inputs"
    end
    verify = lambda do |external|
      verify_selection!(evidence.fetch("configuration"), evidence.fetch("checkpoint"), external)
      record = external && @record_builder.call(external)
      unless record_fingerprint(record) == evidence.fetch("record")
        raise Provider::AccountData::StaleWriter, "Account request inputs changed after capture"
      end
    end
    if external_account
      resolver.with_verified_binding(external_account, batch.source_binding, &verify)
    else
      verify.call(nil)
    end
    true
  end

  def self.attach(page, evidence)
    unless page.is_a?(Provider::AccountData::Page) && page.evidence.keys.none? { |key| key.to_s == EVIDENCE_KEY }
      raise Provider::AccountData::InvalidResponse, "Provider evidence uses a reserved runtime key"
    end
    Provider::AccountData::Page.new(records: page.records, complete: page.complete?, mode: page.mode,
      next_cursor: page.next_cursor, checkpoint_cursor: page.checkpoint_cursor, progress_cursor: page.progress_cursor,
      removed_ids: page.removed_ids, coverage: page.coverage, warnings: page.warnings,
      evidence: page.evidence.merge(EVIDENCE_KEY => evidence))
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    attr_reader :connection, :sync, :stream, :external_account

    def scope_key
      external_account ? "account:#{external_account.id}" : "connection"
    end

    def scope(request_key)
      { "connection_id" => connection.id, "family_id" => connection.family_id, "sync_id" => sync.id,
        "stream" => stream, "external_account_id" => external_account&.id,
        "identity_namespace" => external_account&.identity_namespace, "request_key" => request_key }
    end

    def configuration_values(connection, sync, external)
      values = { "connection_start" => connection.sync_start_date, "external_start" => external&.sync_start_date,
        "sync_start" => sync.window_start_date, "sync_end" => sync.window_end_date, "sync_created_at" => sync.created_at }
      values["history_metadata"] = external&.metadata&.slice(*@history_metadata_keys) if @history_metadata_keys.any?
      values
    end

    def verify_selection!(configuration, checkpoint, external)
      current_sync = Sync.find_by(id: sync.id, syncable_type: "ProviderConnection", syncable_id: connection.id)
      current = connection.provider_sync_checkpoints.where(stream: stream, scope_key: scope_key).lock.first
      unless current_sync && configuration == fingerprint(configuration_values(connection, current_sync, external)) &&
          checkpoint == checkpoint_fingerprint(current)
        raise Provider::AccountData::StaleWriter, "Request window configuration or checkpoint changed after selection"
      end
    end

    def resolver
      Provider::AccountData::GenerationAccounts.new(connection, resource: stream, identity_namespace: external_account.identity_namespace)
    end

    def current_external
      return unless external_account
      connection.external_accounts.find_by!(id: external_account.id, family_id: connection.family_id,
        identity_namespace: external_account.identity_namespace)
    rescue ActiveRecord::RecordNotFound
      raise Provider::AccountData::StaleWriter, "Request account identity changed", cause: nil
    end

    def record_fingerprint(record)
      fingerprint(record && { "kind" => record.kind, "attributes" => record.attributes })
    end

    def fingerprint(value)
      Provider::AccountData::RuntimeInputs.fingerprint(value, purpose: "provider-request-inputs/v1")
    end

    def copy(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end

    def require_transaction!
      raise ArgumentError, "Request inputs require the grant transaction" if ProviderConnection.connection.open_transactions.zero?
    end
end
