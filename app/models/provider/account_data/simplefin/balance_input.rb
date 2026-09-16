# Captures the sparse-history classifier only after this exact Sync has retained
# its transaction stream. RequestInputs fingerprints and rechecks this value.
class Provider::AccountData::Simplefin::BalanceInput
  MAX_BATCH_BYTES = 32 * 1024 * 1024

  def initialize(connection:, sync:, external_account:)
    @connection, @sync, @external = connection, sync, external_account
  end

  def capture
    unless ProviderConnection.connection.open_transactions.positive? && connection.provider_key == "simplefin" &&
        sync.syncable_type == "ProviderConnection" && sync.syncable_id == connection.id &&
        external.provider_connection_id == connection.id && external.family_id == connection.family_id
      raise Provider::AccountData::StaleWriter, "SimpleFIN classification requires its admitted source request"
    end
    checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "transactions", scope_key: "account:#{external.id}",
      family_id: connection.family_id, external_account_id: external.id)
    scope = connection.ingestion_batches.where(family_id: connection.family_id, external_account_id: external.id,
      sync_id: sync.id, origin_kind: "provider", stream: "transactions", scope_key: "account:#{external.id}", generation_role: nil)
    # Only headers are needed from the completed page. Do not decrypt another
    # response merely to prove completion and its original publication binding.
    terminal = scope.select(:id, :status, :complete, :source_binding).find_by(id: checkpoint.ingestion_batch_id)
    # A retry may have a new sequence-zero page and a fresh factory snapshot.
    # Keep the first admitted baseline of this logical Sync, before any of its
    # transactions were posted. Both endpoints must still have the same binding.
    header = scope.order(:writer_epoch, :sequence, :id).pick(:id, Arel.sql("octet_length(payload)"))
    unless terminal && terminal.applied? && terminal.complete? &&
        checkpoint.state["progress"].nil? && header && header.last.to_i <= MAX_BATCH_BYTES
      raise Provider::AccountData::StaleWriter, "SimpleFIN balance requires this Sync's completed transaction stream"
    end
    first = scope.where(id: header.first).where("octet_length(payload) <= ?", MAX_BATCH_BYTES).first!
    unless first.applied? && first.sequence.zero?
      raise Provider::AccountData::StaleWriter, "SimpleFIN transaction baseline is missing"
    end
    resolver = Provider::AccountData::GenerationAccounts.new(connection, resource: "transactions", identity_namespace: external.identity_namespace)
    binding = resolver.capture_one(external)
    unless binding["publication"] == "ledger" && first.source_binding == binding && terminal.source_binding == binding
      raise Provider::AccountData::StaleWriter, "SimpleFIN transaction authority changed before balance classification"
    end
    baseline = Ingestion::Codec.load(first.payload).evidence.fetch("balance_policy_baseline")
    reader = Ingestion::BalancePolicies::Simplefin::Snapshot.new(connection: connection, observed_at: sync.created_at,
      configuration: baseline.slice("enabled", "settings"))
    {
      "version" => 1, "baseline_batch_id" => first.id,
      "transaction_checkpoint" => checkpoint.attributes.slice("id", "lock_version", "ingestion_batch_id"),
      "snapshot" => reader.refresh_raw_history(external: external, baseline: baseline)
    }
  rescue ActiveRecord::RecordNotFound, KeyError, TypeError, NoMethodError, Ingestion::BalancePolicies::Simplefin::InvalidSnapshot
    raise Provider::AccountData::StaleWriter, "SimpleFIN transaction classification input is missing or invalid", cause: nil
  end

  private
    attr_reader :connection, :sync, :external
end
