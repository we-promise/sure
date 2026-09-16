# Store this JSON value explicitly on the account child sync. Resolution follows
# the named provider sync and artifact; it never searches for the latest export.
class Provider::AccountData::Ibkr::EquityHandoff
  KEYS = %w[version family_id account_id provider_connection_id provider_sync_id external_account_id account_provider_id source_batch_id
    inventory_batch_id source_policy_version account_provider_revision writer_epoch observed_on statement_sha256 equity_payload_sha256].freeze
  attr_reader :payload

  def self.load(payload)
    new(payload)
  end

  def initialize(payload)
    raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == KEYS.sort && payload["version"] == 1
    raise ArgumentError unless payload["writer_epoch"].is_a?(Integer) && payload["writer_epoch"] >= 0
    raise ArgumentError unless payload["account_provider_revision"].is_a?(Integer) && payload["account_provider_revision"] >= 0
    (KEYS - %w[version writer_epoch account_provider_revision]).each { |key| raise ArgumentError unless payload[key].is_a?(String) && payload[key].present? }
    %w[statement_sha256 equity_payload_sha256].each { |key| raise ArgumentError unless payload[key].match?(/\A[0-9a-f]{64}\z/) }
    raise ArgumentError unless Date.iso8601(payload["observed_on"]).iso8601 == payload["observed_on"]
    @payload = Provider::AccountData::MigrationManifest.copy_value(payload)
    freeze
  end

  def resolve(account:, provider_sync:)
    selected = assert_selection!(account: account, provider_sync: provider_sync)
    connection, external, policy = selected.values_at(:connection, :external_account, :source_policy)
    batch = connection.ingestion_batches.where(family_id: account.family_id, sync_id: provider_sync.id, external_account_id: external.id).find(payload.fetch("source_batch_id"))
    unless batch.origin_kind == "provider" && batch.stream == "equity_snapshots" && batch.mode == "snapshot" && batch.complete? &&
        batch.scope_key == "account:#{external.id}" && %w[captured applied].include?(batch.status) &&
        batch.writer_epoch == payload.fetch("writer_epoch") && batch.source_policy_version == policy.id &&
        Ingestion::HistoricalBalances.fingerprint(batch.payload) == payload.fetch("equity_payload_sha256")
      raise Provider::AccountData::InvalidResponse, "IBKR historical handoff evidence does not match"
    end
    snapshot = Provider::AccountData::Ibkr::EquitySnapshot.load(batch.payload)
    original = Provider::AccountData::Ibkr::Archive.resolve(connection: connection, sync: provider_sync,
      observed_at: provider_sync.created_at, source_batch_id: payload.fetch("inventory_batch_id"))
    expected_origin = { "inventory_batch_id" => original.fetch(:batch).id,
      "inventory_payload_sha256" => Ingestion::HistoricalBalances.fingerprint(original.fetch(:batch).payload), "provider_sync_id" => provider_sync.id,
      "account_provider_id" => payload.fetch("account_provider_id"), "account_provider_revision" => payload.fetch("account_provider_revision") }
    unless snapshot[:source_artifact] == expected_origin && snapshot[:external_id] == external.external_id && snapshot[:currency] == account.currency &&
        snapshot[:observed_on].iso8601 == payload.fetch("observed_on") && snapshot[:statement_sha256] == payload.fetch("statement_sha256") &&
        original.fetch(:export).statement.fingerprint == payload.fetch("statement_sha256") &&
        original.fetch(:export).scope.fetch("observed_on") == payload.fetch("observed_on")
      raise Provider::AccountData::InvalidResponse, "IBKR historical handoff does not identify its original export"
    end
    self.class.assert_source_current!(account: account, external_account: external, source_batch: batch)
    { external_account: external, source_batch: batch }
  rescue ActiveRecord::RecordNotFound, ArgumentError, KeyError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid IBKR historical handoff", cause: nil
  end

  # Queue admission already holds the provider Sync and Account locks. Check
  # only routing here: reacquiring a request grant would invert that lock order.
  # This closes the gap between equity capture and selecting the child input.
  def assert_selection!(account:, provider_sync:, lock: false)
    if lock && Account.connection.open_transactions.zero?
      raise ArgumentError, "Locked handoff selection requires a transaction"
    end
    unless account.id == payload.fetch("account_id") && account.family_id == payload.fetch("family_id") &&
        provider_sync.id == payload.fetch("provider_sync_id") && provider_sync.syncable_type == "ProviderConnection" &&
        provider_sync.syncable_id == payload.fetch("provider_connection_id")
      raise Provider::AccountData::InvalidResponse, "IBKR historical handoff belongs to another account or sync"
    end
    connection = account.family.provider_connections.find(payload.fetch("provider_connection_id"))
    externals = connection.external_accounts.where(family_id: account.family_id)
    externals = externals.lock("FOR UPDATE NOWAIT") if lock
    external = externals.find(payload.fetch("external_account_id"))
    links = AccountProvider.where(external_account_id: external.id)
    links = links.lock("FOR UPDATE NOWAIT") if lock
    link = links.find_by(id: payload.fetch("account_provider_id"))
    policies = Account::SourcePolicy.active.where(account: account, resource: "historical_balances")
    policies = policies.lock("FOR UPDATE NOWAIT") if lock
    policy = policies.first
    control = connection.provider_migration_control
    unless connection.provider_key == "ibkr" && external.provider_key == "ibkr" && connection.good? && !connection.scheduled_for_deletion &&
        (control.nil? || control.native_owned?) &&
        link&.account_id == account.id && link.family_id == account.family_id && link.provider_key == "ibkr" &&
        link.lock_version == payload.fetch("account_provider_revision") &&
        policy&.id == payload.fetch("source_policy_version") && policy.account_provider_id == payload.fetch("account_provider_id")
      raise Provider::AccountData::StaleWriter, "IBKR historical handoff no longer owns this account"
    end
    { connection: connection, external_account: external, source_policy: policy }
  rescue ActiveRecord::RecordNotFound
    raise Provider::AccountData::StaleWriter, "IBKR historical handoff no longer owns this account", cause: nil
  end

  # Worker epochs may change while the same provider Sync finishes dispatching.
  # Only a fully proved, selected account input can survive that change. Older
  # standalone snapshots retain their original strict-epoch behavior.
  def self.with_source_grant(source_batch:, &block)
    connection = source_batch.provider_connection
    snapshot = Provider::AccountData::Ibkr::EquitySnapshot.load(source_batch.payload)
    artifact = snapshot[:source_artifact]
    return connection.with_lock(&block) unless artifact

    original = Provider::AccountData::Ibkr::Archive.resolve(connection: connection, sync: source_batch.sync,
      observed_at: source_batch.sync.created_at, source_batch_id: artifact.fetch("inventory_batch_id"))
    with_inventory_grant(connection: connection, inventory_batch: original.fetch(:batch), sync: source_batch.sync, &block)
  end

  def self.with_inventory_grant(connection:, inventory_batch:, sync:, &block)
    capture = Ingestion::Codec.load(inventory_batch.payload).evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY]
    unless capture
      return connection.with_lock do
        unless inventory_batch.writer_epoch == connection.writer_epoch
          raise Provider::AccountData::StaleWriter, "Older IBKR inventory has no cross-epoch authorization"
        end
        block.call
      end
    end

    Provider::AccountData::RequestGrant.with_verified_capture!(connection: connection, capture: capture,
      require_runtime_inputs: true, scope_sync: sync, &block)
  end

  def self.assert_source_current!(account:, external_account:, source_batch:, require_selection: true)
    connection = external_account.provider_connection.reload
    unless connection.provider_key == "ibkr" && external_account.provider_key == "ibkr" &&
        source_batch.provider_connection_id == connection.id && source_batch.external_account_id == external_account.id &&
        source_batch.family_id == account.family_id && connection.family_id == account.family_id
      raise Provider::AccountData::InvalidResponse, "Historical source has another owner"
    end
    snapshot = Provider::AccountData::Ibkr::EquitySnapshot.load(source_batch.payload)
    artifact = snapshot[:source_artifact]
    grant = nil
    if artifact
      original = Provider::AccountData::Ibkr::Archive.resolve(connection: connection, sync: source_batch.sync,
        observed_at: source_batch.sync.created_at, source_batch_id: artifact.fetch("inventory_batch_id"))
      unless artifact.fetch("provider_sync_id") == source_batch.sync_id &&
          artifact.fetch("inventory_payload_sha256") == Ingestion::HistoricalBalances.fingerprint(original.fetch(:batch).payload) &&
          snapshot[:statement_sha256] == original.fetch(:export).statement.fingerprint &&
          snapshot[:observed_on].iso8601 == original.fetch(:export).scope.fetch("observed_on")
        raise Provider::AccountData::InvalidResponse, "Historical source differs from its original export"
      end
      grant = Ingestion::Codec.load(original.fetch(:batch).payload).evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY]
      if grant
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: grant,
          require_runtime_inputs: true, scope_sync: source_batch.sync)
      end
    end
    if source_batch.writer_epoch > connection.writer_epoch
      raise Provider::AccountData::StaleWriter, "Historical source is newer than the current writer epoch"
    end
    same_epoch = source_batch.writer_epoch == connection.writer_epoch
    return true if same_epoch && !grant
    if grant && !require_selection
      selection = Account::SyncSource.find_by(account: account, family_id: account.family_id, resource: "historical_balances")
      selected = selection&.account_sync_input&.source_batch
      if selected && selected.provider_connection_id == source_batch.provider_connection_id &&
          selected.id != source_batch.id && selected.writer_epoch >= source_batch.writer_epoch
        raise Provider::AccountData::StaleWriter, "A newer historical source has already been selected"
      end
      # Capture precedes selection. The caller's current execution fence owns
      # this exact provider Sync; a crash here must not require its missing child.
      return true
    end

    unless grant && selected_source?(account: account, external_account: external_account, source_batch: source_batch,
        snapshot: snapshot, artifact: artifact)
      raise Provider::AccountData::StaleWriter, "Historical source has no selected proof for this worker epoch"
    end
    true
  rescue ActiveRecord::RecordNotFound, ArgumentError, KeyError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid historical source proof", cause: nil
  end

  def self.selected_source?(account:, external_account:, source_batch:, snapshot:, artifact:)
    selection = Account::SyncSource.find_by(account: account, family_id: account.family_id, resource: "historical_balances")
    input = selection&.account_sync_input
    return false unless input && input.account_id == account.id && input.family_id == account.family_id &&
      input.kind == "ibkr_equity" && input.resource == "historical_balances" &&
      input.source_batch_id == source_batch.id && input.provider_sync_id == source_batch.sync_id &&
      input.payload_digest == Ingestion::HistoricalBalances.fingerprint(input.payload) &&
      input.sync.verify_account_inputs!.any? { |sealed| sealed.id == input.id }

    expected = {
      "version" => 1, "family_id" => account.family_id, "account_id" => account.id,
      "provider_connection_id" => source_batch.provider_connection_id, "provider_sync_id" => source_batch.sync_id,
      "external_account_id" => external_account.id, "account_provider_id" => artifact.fetch("account_provider_id"),
      "account_provider_revision" => artifact.fetch("account_provider_revision"), "source_batch_id" => source_batch.id,
      "inventory_batch_id" => artifact.fetch("inventory_batch_id"), "source_policy_version" => source_batch.source_policy_version,
      "writer_epoch" => source_batch.writer_epoch, "observed_on" => snapshot[:observed_on].iso8601,
      "statement_sha256" => snapshot[:statement_sha256], "equity_payload_sha256" => Ingestion::HistoricalBalances.fingerprint(source_batch.payload)
    }
    input.handoff.payload == expected
  end
  private_class_method :selected_source?

  def inspect
    "#<#{self.class.name}>"
  end
end
