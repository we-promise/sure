require "digest"
require "securerandom"

# Installs retained starting input, not provider coverage or activation authority.
# The original receipt survives every native activity checkpoint advancement.
class Provider::AccountData::Binance::HistoryBootstrap
  class Conflict < StandardError; end

  FORMAT = "binance-history-installation/v1".freeze
  STREAM = "legacy_binance_history".freeze
  MAX_BYTES = 24 * 1024 * 1024
  MAX_CHECKPOINT_BYTES = 1024 * 1024
  Result = Data.define(:checkpoint_id, :batch_id, :replayed)

  def initialize(mapping:, family:)
    @mapping, @family = mapping, family
  end

  def install(expected_context: nil)
    raise Conflict, "Configure encryption before installing retained history" unless ActiveRecordEncryptionConfig.ready?
    Plan.new(mapping: @mapping, family: @family).with_retained_plan(expected_context: expected_context) do |plan|
      raise Conflict, "Resolve every retained Binance history blocker before installation" unless plan.ready?
      context = plan.document.fetch("context")
      connection = ProviderConnection.lock.find_by!(id: context.fetch("provider_connection_id"), family_id: @family.id)
      external = ExternalAccount.find_by!(id: context.fetch("external_account_id"), provider_connection: connection, family: @family)
      account = Account.find_by!(id: context.fetch("account_id"), family: @family)
      refuse_native_progress!(connection)
      identity = verified_identity_checkpoint!(connection, external)
      # A verified checkpoint is a retained sweep, not permission to skip today's
      # final inventory. This public replay checks exact identity/context again.
      result = Ingestion::IdentityBootstrap.new(mapping: @mapping, family: @family,
        page_size: identity.state.fetch("page_size")).run
      raise Conflict, "Financial identities need a completed verification sweep" unless result.verified?

      proofs = verify_members!(plan, account, external)
      document = { "format" => FORMAT, "plan" => plan.document, "proofs" => proofs,
        "identity_checkpoint" => identity.reload.attributes.except("created_at", "updated_at"),
        "upstream_history_complete" => false, "requires_cutover_reverification" => true }
      raise Conflict, "Retained history receipt exceeds its bound" if Value.dump(document).bytesize > MAX_BYTES
      checkpoint_scope = connection.provider_sync_checkpoints.where(stream: STREAM, scope_key: "account:#{external.id}")
      checkpoint = checkpoint_scope.lock.first
      receipts = connection.ingestion_batches.where(stream: STREAM, external_account: external)
      if checkpoint
        original = self.class.read_receipt!(checkpoint, connection: connection)
        unless original.except("signature", "installation") == document && receipts.pluck(:id) == [ checkpoint.ingestion_batch_id ]
          raise Conflict, "Installed history belongs to another retained context or identity proof"
        end
        next Result.new(checkpoint_id: checkpoint.id, batch_id: checkpoint.ingestion_batch_id, replayed: true)
      end
      raise Conflict, "Retained history requires its original installation checkpoint" if receipts.exists?

      document["installation"] = { "checkpoint_id" => SecureRandom.uuid, "batch_id" => SecureRandom.uuid }
      payload = document.merge("signature" => Keys.configured.sign(Value.dump(document)))
      batch = receipts.create!(id: document.fetch("installation").fetch("batch_id"), family: @family, origin_kind: "migration", scope_key: "account:#{external.id}",
        sequence: 0, schema_version: 1, mode: "unknown", complete: false, payload: payload,
        idempotency_key: "#{FORMAT}:#{@mapping.id}:#{context.fetch('copy_run_id')}")
      batch.update!(status: "applied", applied_at: Time.current)
      checkpoint = checkpoint_scope.create!(id: document.fetch("installation").fetch("checkpoint_id"), family: @family, external_account: external, ingestion_batch: batch, schema_version: 1,
        state: { "format" => FORMAT, "batch_id" => batch.id, "receipt_digest" => Digest::SHA256.hexdigest(Value.dump(payload)) })
      Result.new(checkpoint_id: checkpoint.id, batch_id: batch.id, replayed: false)
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, ActiveRecord::LockWaitTimeout, ActiveRecord::SerializationFailure,
      Plan::InvalidContext, Ingestion::LegacyIdentityEvidence::InvalidEvidence, Keys::InvalidConfiguration, Keys::InvalidSignature => error
    capture_failure(error)
    raise Conflict, "Retained Binance history requires retry or reconciliation", cause: nil
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Reverify an existing installation after a fresh identity sweep. The signed
  # receipt retains the original sweep timestamp/revision; a later sweep may
  # advance them, not its checkpoint UUID, capture inventory or proof context.
  # This command never installs missing state or rewrites the original receipt.
  def verify!(checkpoint_id:, batch_id:, receipt_digest:)
    Plan.new(mapping: @mapping, family: @family).with_retained_plan do |plan|
      raise Conflict, "Resolve retained Binance history blockers before verification" unless plan.ready?
      context = plan.document.fetch("context")
      connection = ProviderConnection.lock.find_by!(id: context.fetch("provider_connection_id"), family_id: @family.id)
      external = connection.external_accounts.find_by!(id: context.fetch("external_account_id"), family_id: @family.id)
      account = Account.find_by!(id: context.fetch("account_id"), family_id: @family.id)
      refuse_native_progress!(connection)
      checkpoint = connection.provider_sync_checkpoints.where(stream: STREAM, scope_key: "account:#{external.id}")
        .where("octet_length(state) <= ?", MAX_CHECKPOINT_BYTES * 2).lock.find(checkpoint_id)
      unless checkpoint.ingestion_batch_id == batch_id && checkpoint.state["receipt_digest"] == receipt_digest
        raise Conflict, "Retained history differs from its preparation receipt"
      end
      original = self.class.read_receipt!(checkpoint, connection: connection)
      identity = verified_identity_checkpoint!(connection, external)
      result = Ingestion::IdentityBootstrap.new(mapping: @mapping, family: @family,
        page_size: identity.state.fetch("page_size")).run
      raise Conflict, "Financial identities require a completed verification sweep" unless result.verified?
      current_identity = identity.reload.attributes.except("created_at", "updated_at")
      original_identity = original.fetch("identity_checkpoint")
      unless original.fetch("plan") == plan.document && original.fetch("proofs") == verify_members!(plan, account, external) &&
          original_identity["lock_version"].is_a?(Integer) && current_identity["lock_version"].is_a?(Integer) &&
          current_identity["lock_version"] >= original_identity["lock_version"] &&
          identity_capture(original_identity) == identity_capture(current_identity) &&
          connection.ingestion_batches.where(stream: STREAM, external_account: external).pluck(:id) == [ batch_id ]
        raise Conflict, "Installed history no longer matches its retained source and financial proofs"
      end
      Result.new(checkpoint_id: checkpoint.id, batch_id: batch_id, replayed: true)
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, ActiveRecord::LockWaitTimeout, ActiveRecord::SerializationFailure,
      Plan::InvalidContext, Ingestion::LegacyIdentityEvidence::InvalidEvidence, Keys::InvalidConfiguration, Keys::InvalidSignature,
      KeyError, TypeError, ArgumentError => error
    capture_failure(error)
    raise Conflict, "Retained Binance history verification requires retry or reconciliation", cause: nil
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Explicit trusted RuntimeContext input. The complete descriptor participates
  # in RequestGrant's keyed live fingerprint before HTTP and at publication.
  # It excludes ordinary activities progress, which advances independently.
  def self.runtime_input(connection)
    raise Conflict, "Retained history belongs to another provider" unless connection.provider_key == "binance"
    scope = connection.provider_sync_checkpoints.where(stream: STREAM)
    inventory = scope.order(:id).limit(2).pluck(:id, Arel.sql("octet_length(state)"))
    if inventory.empty?
      if ProviderMigrationControl.where(provider_connection: connection).exists? || connection.ingestion_batches.where(stream: STREAM).exists?
        raise Conflict, "Migrated Binance history requires its original installed seed"
      end
      return { "checkpoint" => nil, "seed" => {} }
    end
    unless inventory.one? && inventory.sole.last.to_i <= MAX_CHECKPOINT_BYTES * 2
      raise Conflict, "Retained Binance history has ambiguous or oversized installation state"
    end
    checkpoint = scope.where("octet_length(state) <= ?", MAX_CHECKPOINT_BYTES * 2).find(inventory.sole.first)
    payload = read_receipt!(checkpoint, connection: connection)
    context = payload.fetch("plan").fetch("context")
    external = connection.external_accounts.find_by!(id: context.fetch("external_account_id"), family_id: connection.family_id,
      identity_namespace: context.fetch("identity_namespace"), external_id: context.fetch("external_account_external_id"))
    unless connection.region == context.fetch("region") && connection.environment == context.fetch("environment")
      raise Conflict, "Installed history deployment changed"
    end
    link = AccountProvider.find_by(external_account_id: external.id)
    unless link
      Provider::AccountData::RetainedAccountBinding.assert_detached!(external_account: external,
        control_id: context.fetch("migration_control_id"), account_id: context.fetch("account_id"),
        account_provider_id: context.fetch("account_provider_id"), legacy_type: "BinanceAccount", legacy_id: context.fetch("legacy_account_id"))
      # Authenticate and retain the installation, but do not seed a new stream
      # from the removed financial owner's previous imported-history boundary.
      return Manifest.copy_value("checkpoint" => checkpoint.attributes, "seed" => {})
    end
    unless link.id == context.fetch("account_provider_id") && link.family_id == connection.family_id &&
        link.account_id == context.fetch("account_id") && link.provider_key == "binance" &&
        link.provider_type == "BinanceAccount" && link.provider_id == context.fetch("legacy_account_id") &&
        link.lock_version == context.fetch("account_provider_revision") &&
        Account.where(id: link.account_id, family_id: connection.family_id, currency: context.fetch("account_currency"),
          accountable_type: context.fetch("accountable_type"), accountable_id: context.fetch("accountable_id")).exists?
      raise Conflict, "Installed history financial account ownership changed"
    end
    Manifest.copy_value("checkpoint" => checkpoint.attributes,
      "seed" => payload.fetch("plan").fetch("candidate_cached_history"))
  rescue Conflict, Provider::AccountData::MigrationCopier::Conflict, ActiveRecord::RecordNotFound, Keys::InvalidConfiguration, Keys::InvalidSignature, ArgumentError, TypeError, KeyError
    raise Provider::AccountData::StaleWriter, "Binance history installation changed or is unavailable", cause: nil
  end

  def self.read_receipt!(checkpoint, connection:)
    unless checkpoint.family_id == connection.family_id && checkpoint.provider_connection_id == connection.id &&
        checkpoint.stream == STREAM && checkpoint.scope_key == "account:#{checkpoint.external_account_id}" && checkpoint.external_account_id &&
        checkpoint.provider_authorization_id.nil? && checkpoint.provider_sync_generation_id.nil? && checkpoint.schema_version == 1 &&
        checkpoint.cursor.nil? && checkpoint.covered_through.nil? &&
        checkpoint.state.is_a?(Hash) && checkpoint.state.keys.sort == %w[batch_id format receipt_digest] &&
        checkpoint.state["format"] == FORMAT && checkpoint.state["batch_id"] == checkpoint.ingestion_batch_id
      raise Conflict, "Retained history checkpoint has unrelated execution state"
    end
    batches = connection.ingestion_batches.where(id: checkpoint.ingestion_batch_id, family_id: connection.family_id)
    bytes = batches.pick(Arel.sql("octet_length(payload)"))
    raise Conflict, "Retained history receipt is missing or exceeds its bound" unless bytes && bytes <= MAX_BYTES * 2
    batch = batches.where("octet_length(payload) <= ?", MAX_BYTES * 2).first!
    unless batch.origin_kind == "migration" && batch.stream == STREAM && batch.scope_key == checkpoint.scope_key &&
        batch.external_account_id == checkpoint.external_account_id && batch.applied? && batch.applied_at &&
        batch.mode == "unknown" && !batch.complete? && batch.coverage == {} && batch.ruleset_snapshot == {} && batch.source_binding == {} &&
        batch.sync_id.nil? && batch.provider_authorization_id.nil? && batch.provider_sync_generation_id.nil? && batch.writer_epoch.nil? &&
        batch.source_policy_version.nil? && batch.schema_version == 1 && batch.sequence.zero? && batch.import_id.nil? && batch.account_statement_id.nil?
      raise Conflict, "Retained history receipt has unrelated execution state"
    end
    payload = batch.payload
    unless payload.is_a?(Hash) && payload.keys.sort == %w[format identity_checkpoint installation plan proofs requires_cutover_reverification signature upstream_history_complete] &&
        payload["format"] == FORMAT && payload["upstream_history_complete"] == false && payload["requires_cutover_reverification"] == true &&
        payload["installation"] == { "checkpoint_id" => checkpoint.id, "batch_id" => batch.id } &&
        Digest::SHA256.hexdigest(Value.dump(payload)) == checkpoint.state["receipt_digest"]
      raise Conflict, "Retained history receipt differs from its installation"
    end
    Keys.configured.verify!(payload.fetch("signature"), Value.dump(payload.except("signature")))
    context = payload.fetch("plan").fetch("context")
    unless context.values_at("family_id", "provider_connection_id", "external_account_id", "provider_key") ==
        [ connection.family_id, connection.id, checkpoint.external_account_id, "binance" ] &&
        payload.fetch("plan").fetch("blockers").empty? && payload.fetch("plan").fetch("candidate_cached_history").is_a?(Hash)
      raise Conflict, "Retained history receipt belongs to another source"
    end
    payload
  end

  private
    Plan = Provider::AccountData::Binance::HistoryBootstrapPlan
    Value = Provider::AccountData::MigrationValue
    Manifest = Provider::AccountData::MigrationManifest
    Keys = Ingestion::IdentitySigningKeys

    def identity_capture(document)
      document.except("lock_version").merge("state" => document.fetch("state").except("verified_at"))
    end

    def refuse_native_progress!(connection)
      unless connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? && connection.syncs.none? &&
          connection.ingestion_batches.where.not(origin_kind: "migration").none? &&
          connection.provider_sync_checkpoints.where(stream: "activities").none?
        raise Conflict, "History installation cannot replace native activity or progress"
      end
    end

    def verified_identity_checkpoint!(connection, external)
      scope = connection.provider_sync_checkpoints.where(stream: Ingestion::IdentityBootstrap::STREAM, scope_key: "account:#{external.id}")
      bytes = scope.pick(Arel.sql("octet_length(state)"))
      raise Conflict, "A bounded verified identity checkpoint is required" unless bytes && bytes <= MAX_CHECKPOINT_BYTES * 2
      checkpoint = scope.lock.first!
      unless checkpoint.external_account_id == external.id && checkpoint.family_id == @family.id && checkpoint.state["phase"] == "verified"
        raise Conflict, "Financial identities need a completed verification sweep"
      end
      checkpoint
    end

    def verify_members!(plan, account, external)
      members = plan.document.fetch("rows").flat_map { |row| row.fetch("members") }
      selected = account.entries.where(id: members.map { |member| member.fetch("entry_id") })
      entries = selected.select(:id, :entryable_type, :entryable_id, :source, :external_id, :plaid_id).order(:id)
        .lock("FOR UPDATE NOWAIT").index_by(&:id)
      %w[Trade Transaction].each do |type|
        ids = entries.values.select { |entry| entry.entryable_type == type }.map(&:entryable_id)
        type.constantize.where(id: ids).select(:id).order(:id).lock("FOR UPDATE NOWAIT").load
      end
      identities = selected.joins("LEFT JOIN transactions bootstrap_transactions ON entries.entryable_type = 'Transaction' AND bootstrap_transactions.id = entries.entryable_id")
      identity_sql = Ingestion::FinancialIdentityState.sql
      bytes = identities.pick(Arel.sql("COALESCE(SUM(octet_length((#{identity_sql})::text)), 0)"))
      raise Conflict, "Retained financial identity state exceeds its bound" if bytes.to_i > MAX_BYTES / 2
      states = identities.pluck(:id, Arel.sql(identity_sql)).to_h
      Ingestion::LegacyIdentityEvidence.with_validation_cache do
        members.map do |member|
          entry = entries.fetch(member.fetch("entry_id"))
          unless entry.entryable_type == member.fetch("entryable_type") && entry.entryable_id == member.fetch("entryable_id") &&
              entry.source == "binance" && entry.external_id == member.fetch("external_id") && entry.plaid_id.blank? &&
              Entry.where(entryable_type: entry.entryable_type, entryable_id: entry.entryable_id).count == 1
            raise Conflict, "Cached history financial identity changed"
          end
          record = SourceRecord.where(external_account: external, account: account, family_id: @family.id,
            external_id: member.fetch("external_id"), withdrawn: false).lock.sole
          posting = record.entry_sources.lock.sole
          unless record.kind == "activity" && posting.active? && posting.role == "posting" && posting.bootstrap_identity_role == "current" && posting.entry_id == entry.id &&
              record.ingestion_batch_id == posting.bootstrap_batch_id
            raise Conflict, "Cached history requires its active original financial identity proof"
          end
          posting.association(:entry).target = entry
          row = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: record).fetch(:row)
          live = states.fetch(entry.id)
          unless row.fetch("identity_state") == live && row.fetch("entry_id") == entry.id && row.fetch("entryable_type") == entry.entryable_type
            raise Conflict, "Cached history financial identity changed after proof publication"
          end
          { "entry_id" => entry.id, "entry_source_id" => posting.id, "source_record_id" => record.id,
            "bootstrap_batch_id" => posting.bootstrap_batch_id, "identity_state" => live }
        end
      end
    end

    def capture_failure(error)
      DebugLogEntry.capture(category: "provider_migration_error", level: "warn", message: "Binance history seed requires retry or review",
        source: self.class.name, provider_key: "binance", family: @family,
        metadata: { migration_mapping_id: @mapping&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
