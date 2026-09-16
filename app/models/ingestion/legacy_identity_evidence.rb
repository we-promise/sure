require "digest"
require "openssl"

# Permanent provenance for a reviewed legacy financial identity. This is neither
# provider coverage nor a new financial event. Later observations may replace a
# SourceRecord's current batch; EntrySource keeps this original batch forever.
class Ingestion::LegacyIdentityEvidence
  class InvalidEvidence < Provider::AccountData::InvalidResponse; end

  FORMAT = "provider-financial-identities/v1".freeze
  STREAM = "legacy_financial_identities".freeze
  PLAN_FORMATS = %w[plaid-financial-identity-v1 provider-financial-identity-plan-v1].freeze
  MAX_ROWS = 500
  MAX_BYTES = 96 * 1024 * 1024
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_ARCHIVE_CHUNKS = 1_024
  IDENTITY_KEYS = %w[external_id input_external_id input_occurrence pending role].freeze

  class << self
    # Only the current transaction and exact, immutable batch object may reuse
    # proof parsing. Keep one batch, not an account's complete evidence history.
    def with_validation_cache
      require_transaction!
      key = :provider_financial_identity_validation
      previous = ActiveSupport::IsolatedExecutionState[key]
      ActiveSupport::IsolatedExecutionState[key] = {
        database: ApplicationRecord.connection, transaction: ApplicationRecord.current_transaction, entry: nil
      }
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[key] = previous if key
    end

    # Trusted runtime entrypoint: the source, lock and quiescence evidence is read
    # here, never asserted by a serialized plan or a UI-provided approval flag.
    # The publisher selects/replans the provider's allowlisted planner first.
    def seal(plan:, control:, mapping:)
      require_transaction!
      ApplicationRecord.uncached do
        control = ProviderMigrationControl.lock.find(control.id)
        manifest = Provider::AccountData::MigrationManifest.for(control.provider_key)
        item = manifest.item_type.constantize.find_by!(id: control.legacy_id, family_id: control.family_id)
        Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
        connection = ProviderConnection.lock.find(control.provider_connection_id)
        checkpoint_streams = [ "legacy_state", STREAM ]
        if Provider::AccountData::AuxiliaryCopier.supports?(control.provider_key)
          checkpoint_streams << Provider::AccountData::AuxiliaryCopier.stream_for(control.provider_key)
        end
        checkpoint_streams << Provider::AccountData::Binance::HistoryBootstrap::STREAM if control.provider_key == "binance"
        checkpoint_streams << Provider::AccountData::Plaid::CachedChangeJournal::STREAM if control.provider_key == "plaid"
        unless control.quiescing? && control.writer_epoch.zero? && connection.writer_epoch.zero? &&
            connection.disabled? && connection.lease_owner.nil? && connection.credential_state.blank? &&
            control.lease_owner.nil? && control.high_water_mark["mode"] == "quiesced" &&
            control.high_water_mark["phase"] == "verified" && control.high_water_mark["copy_run_id"].present? &&
            control.audit_results["copy_run_id"] == control.high_water_mark["copy_run_id"] &&
            connection.syncs.none? && connection.ingestion_batches.where.not(origin_kind: "migration").none? &&
            connection.provider_sync_checkpoints.where.not(stream: checkpoint_streams).none?
          raise InvalidEvidence, "Identity capture requires a verified quiesced copy before native execution"
        end
        verify_retained_binance_history!(connection, control) if control.provider_key == "binance"
        mapping = ProviderMigrationMapping.find(mapping.id)
        external = mapping.external_account
        unless mapping.provider_migration_control_id == control.id && mapping.family_id == control.family_id &&
            mapping.role == "external_account" && mapping.legacy_type == manifest.account_type && mapping.verified_at &&
            external && external.provider_connection_id == connection.id && external.family_id == control.family_id
          raise InvalidEvidence, "Identity capture requires this verified account mapping"
        end
        document = normalize_plan(plan)
        link = AccountProvider.find_by!(external_account_id: external.id)
        planned_link = link.attributes.slice("id", "account_id", "external_account_id", "lock_version")
        account = Account.lock.find_by!(id: link.account_id, family_id: control.family_id)
        external.lock!
        link.lock!
        unless link.attributes.slice(*planned_link.keys) == planned_link &&
            AccountProvider.where(external_account_id: external.id).pick(:id) == link.id
          raise InvalidEvidence, "Identity capture account link changed while acquiring its lock"
        end
        bindings = document.fetch("rows").map { |row| resource(row.fetch("kind")) }.uniq.sort.to_h do |stream|
          binding = Provider::AccountData::GenerationAccounts.new(connection, resource: stream,
            identity_namespace: external.identity_namespace).capture_one(external)
          [ stream, binding ]
        end
        mapping.lock!
        unless link.account_id == account.id && link.family_id == account.family_id && link.provider_key == control.provider_key &&
            link.provider_type == manifest.account_type && link.provider_id == mapping.legacy_id
          raise InvalidEvidence, "Identity capture lost its retained account link"
        end
        verify_plan_context!(document, mapping, control, connection, external, link, account)
        verify_legacy_archive!(mapping, control, manifest, link: link, financial: account)
        verify_financial_rows!(document.fetch("rows"), account)
        payload = {
          "format" => FORMAT, "plan" => document,
          "admission" => {
            "control_id" => control.id, "copy_run_id" => control.high_water_mark.fetch("copy_run_id"),
            "family_id" => account.family_id, "account_id" => account.id,
            "provider_key" => control.provider_key, "provider_connection_id" => connection.id,
            "external_account_id" => external.id, "identity_namespace" => external.identity_namespace,
            "account_provider_id" => link.id, "account_provider_revision" => link.lock_version,
            "migration_mapping_id" => mapping.id, "archive_checksum" => mapping.source_checksum,
            "resource_bindings" => bindings, "captured_at" => Time.current.utc.iso8601(6),
            "declared_legacy_fence_held" => true, "requires_cutover_reverification" => true
          }
        }
        immutable(payload.merge("signature" => signature(payload)))
      end
    rescue ActiveRecord::LockWaitTimeout
      raise InvalidEvidence, "Financial identity capture encountered an active edit; retry with a fresh plan", cause: nil
    rescue Ingestion::IdentitySigningKeys::InvalidConfiguration
      raise InvalidEvidence, "Identity capture requires explicit retained signing keys", cause: nil
    rescue ActiveRecord::RecordNotFound, Provider::AccountData::MigrationCopier::Conflict, KeyError, ArgumentError
      raise InvalidEvidence, "Identity capture has invalid or missing context", cause: nil
    end

    def for_observation!(source_record:, require_applied: true)
      raise InvalidEvidence, "An exact source observation is required" unless source_record.is_a?(SourceRecord)
      batch = source_record.ingestion_batch
      payload = validate_batch!(batch, require_applied: require_applied)
      find_identity!(payload, source_record)
    end

    def for_mapping!(entry_source:, source_record:, require_applied: true)
      unless source_record.is_a?(SourceRecord) && entry_source.is_a?(EntrySource) &&
          entry_source.bootstrap_batch_id && entry_source.bootstrap_external_account_id == source_record.external_account_id &&
          entry_source.source_record_id == source_record.id && entry_source.account_id == source_record.account_id &&
          entry_source.family_id == source_record.family_id && entry_source.role == "posting"
        raise InvalidEvidence, "Bootstrap mapping has a different source or account"
      end
      payload = validate_batch!(entry_source.bootstrap_batch, require_applied: require_applied)
      found = find_identity!(payload, source_record)
      row, identity = found.values_at(:row, :identity)
      unless entry_source.entry_identity == row.fetch("entry_id") &&
          (entry_source.entry_id.nil? || entry_source.entry_id == row.fetch("entry_id")) &&
          entry_source.bootstrap_entryable_type == row.fetch("entryable_type") &&
          entry_source.bootstrap_identity_state == row.fetch("identity_state") &&
          (entry_source.entry_id.nil? || entry_source.entry&.entryable_type == row.fetch("entryable_type")) &&
          entry_source.bootstrap_identity_role == identity.fetch("role") && entry_source.match_method == row.fetch("match_method")
        raise InvalidEvidence, "Bootstrap mapping differs from its captured financial identity"
      end
      found
    end

    def validate_batch!(batch, require_applied: true)
      unless batch&.persisted? && batch.origin_kind == "migration" && batch.stream == STREAM &&
          batch.external_account_id && batch.provider_connection_id && batch.sync_id.nil? &&
          batch.import_id.nil? && batch.account_statement_id.nil? && batch.provider_authorization_id.nil? &&
          batch.provider_sync_generation_id.nil? && batch.source_binding == {} && batch.mode == "unknown" && !batch.complete? &&
          batch.coverage == {} && batch.ruleset_snapshot == {} && batch.writer_epoch.nil? && batch.source_policy_version.nil? &&
          batch.schema_version == 1 && %w[captured applying applied].include?(batch.status) &&
          batch.scope_key == "account:#{batch.external_account_id}" && (!require_applied || (batch.applied? && batch.applied_at))
        raise InvalidEvidence, "Unsupported financial identity bootstrap batch"
      end
      persisted = IngestionBatch.uncached do
        IngestionBatch.where(id: batch.id).pick(Arel.sql("octet_length(payload)"), :status, :applied_at)
      end
      stored_bytes, persisted_status, persisted_applied_at = persisted
      raise InvalidEvidence, "Bootstrap evidence exceeds its retained bound" unless stored_bytes && stored_bytes <= MAX_BYTES * 2
      unless persisted_status == batch.status && persisted_applied_at == batch.applied_at
        raise InvalidEvidence, "Bootstrap evidence has stale persisted state"
      end
      payload = batch.payload
      signing_keys = Ingestion::IdentitySigningKeys.configured
      cache = validation_cache
      cached = cache && cache[:entry]
      if cached && cached[:batch].equal?(batch) && cached[:input].equal?(payload) && cached[:capture] == captured_tuple(batch) &&
          cached[:signing_keys] == signing_keys.cache_token
        validate_payload_admission!(cached[:payload], batch)
        return cached[:payload]
      end
      unless payload.is_a?(Hash) && payload.keys.sort == %w[admission format plan signature] && payload["format"] == FORMAT
        raise InvalidEvidence, "Financial identity evidence has no valid runtime attestation"
      end
      signing_keys.verify!(payload["signature"], bounded_serialization(payload.except("signature")))
      plan = normalize_plan(payload.fetch("plan"))
      raise InvalidEvidence, "Bootstrap evidence has inconsistent plan" unless plan == payload["plan"]
      validate_payload_admission!(payload, batch)
      validated = immutable(payload)
      if cache
        freeze_proof_input(payload)
        index = validated.fetch("plan").fetch("rows").each_with_object({}) do |row, identities|
          row.fetch("identities").each do |identity|
            identities[[ row.fetch("kind"), identity.fetch("external_id") ]] = { row: row, identity: identity }.freeze
          end
        end.freeze
        cache[:entry] = { batch: batch, input: payload, capture: immutable(captured_tuple(batch)), payload: validated, index: index,
          signing_keys: signing_keys.cache_token }
      end
      validated
    rescue Ingestion::IdentitySigningKeys::InvalidConfiguration, Ingestion::IdentitySigningKeys::InvalidSignature
      raise InvalidEvidence, "Financial identity evidence has no configured valid signing proof", cause: nil
    rescue KeyError, ArgumentError, ActiveRecord::RecordNotFound
      raise InvalidEvidence, "Malformed financial identity bootstrap evidence", cause: nil
    end

    # Existing Plaid plans predate the explicit input identity list. Preserve
    # their exact IDs and archive-proven pending aliases without new heuristics.
    def normalize_plan(plan)
      unless plan.is_a?(Hash) && PLAN_FORMATS.include?(plan["format"]) && plan["blockers"] == [] &&
          [ true, false ].include?(plan["complete"]) && plan["rows"].is_a?(Array) && plan["rows"].size <= MAX_ROWS
        raise InvalidEvidence, "A ready versioned financial identity plan is required"
      end
      document = plan.deep_dup
      rows = document.fetch("rows")
      rows.each do |row|
        unless row.is_a?(Hash) && %w[transaction activity].include?(row["kind"]) &&
            %w[Transaction Trade].include?(row["entryable_type"]) && row["entry_id"].is_a?(String) &&
            row["entry_id"].match?(Provider::AccountData::LegacyWriterFence::UUID) && identifier?(row["external_id"]) &&
            (row["kind"] != "transaction" || row["entryable_type"] == "Transaction") &&
            %w[legacy_external_id legacy_plaid_id].include?(row["match_method"]) &&
            row["pending_aliases"].is_a?(Array) && row["pending_aliases"].all? { |id| identifier?(id) } &&
            [ true, false ].include?(row["pending"]) && row["financial_snapshot"].is_a?(Array)
          raise InvalidEvidence, "Unsupported financial identity row"
        end
        row["identities"] ||= [ { "external_id" => row.fetch("external_id"), "input_external_id" => row.fetch("external_id"),
          "input_occurrence" => 0, "role" => "current", "pending" => row.fetch("pending") } ] + row.fetch("pending_aliases").map do |id|
          { "external_id" => id, "input_external_id" => id, "input_occurrence" => 0, "role" => "retired_alias", "pending" => false }
        end
        identity_state = Ingestion::FinancialIdentityState.from_snapshot(Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot")))
        if row.key?("identity_state") && row["identity_state"] != identity_state
          raise InvalidEvidence, "Financial identity state differs from its captured snapshot"
        end
        row["identity_state"] = identity_state
        identities = row.fetch("identities")
        unless identities.is_a?(Array) && identities.size.between?(1, 1000) && identities.all? { |identity| valid_identity?(identity) } &&
            identities.map { |identity| identity["external_id"] }.uniq.size == identities.size &&
            identities.count { |identity| identity["role"] == "current" } == 1 &&
            identities.find { |identity| identity["role"] == "current" }["external_id"] == row["external_id"] &&
            identities.find { |identity| identity["role"] == "current" }["pending"] == row["pending"] &&
            identities.select { |identity| identity["role"] == "retired_alias" }.map { |identity| identity["external_id"] }.sort == row["pending_aliases"].sort &&
            (row["kind"] == "transaction" || (identities.size == 1 && !row["pending"]))
          raise InvalidEvidence, "Conflicting current and retired financial identities"
        end
      end
      unless rows.map { |row| row["entry_id"] }.uniq.size == rows.size &&
          rows.flat_map { |row| row["identities"].map { |identity| identity["external_id"] } }.uniq.size == rows.sum { |row| row["identities"].size }
        raise InvalidEvidence, "Financial identity page has duplicate claims"
      end
      bounded_serialization(document)
      document
    end

    private
      # A Binance history seed is retained migration input, not native progress.
      # Re-verifying financial identities must still validate its signed receipt;
      # merely adding its stream to an allowlist would admit unrelated state.
      def verify_retained_binance_history!(connection, control)
        publisher = Provider::AccountData::Binance::HistoryBootstrap
        scope = connection.provider_sync_checkpoints.where(stream: publisher::STREAM)
        inventory = scope.order(:id).limit(2).pluck(:id, Arel.sql("octet_length(state)"))
        receipts = connection.ingestion_batches.where(stream: publisher::STREAM).order(:id).limit(2).pluck(:id)
        return if inventory.empty? && receipts.empty?

        unless inventory.one? && inventory.sole.last.to_i <= publisher::MAX_CHECKPOINT_BYTES * 2 && receipts.one?
          raise InvalidEvidence, "Binance history requires its original bounded installation"
        end
        checkpoint = scope.where("octet_length(state) <= ?", publisher::MAX_CHECKPOINT_BYTES * 2).find(inventory.sole.first)
        document = publisher.read_receipt!(checkpoint, connection: connection)
        context = document.fetch("plan").fetch("context")
        unless receipts == [ checkpoint.ingestion_batch_id ] &&
            context.fetch("migration_control_id") == control.id &&
            context.fetch("copy_run_id") == control.high_water_mark.fetch("copy_run_id")
          raise InvalidEvidence, "Binance history belongs to a different retained copy"
        end
      rescue Provider::AccountData::Binance::HistoryBootstrap::Conflict, Ingestion::IdentitySigningKeys::InvalidSignature,
          ActiveRecord::RecordNotFound, KeyError, TypeError, ArgumentError
        raise InvalidEvidence, "Binance history installation cannot be verified", cause: nil
      end

      def validate_payload_admission!(payload, batch)
        plan = payload.fetch("plan")
        admission = payload.fetch("admission")
        unless admission.is_a?(Hash) && admission["family_id"] == batch.family_id &&
            admission["provider_connection_id"] == batch.provider_connection_id && admission["external_account_id"] == batch.external_account_id &&
            admission["account_id"] == plan["account_id"] && admission["family_id"] == plan["family_id"] &&
            admission["migration_mapping_id"] == plan["migration_mapping_id"] && admission["archive_checksum"] == plan["archive_checksum"] &&
            admission["declared_legacy_fence_held"] == true && admission["copy_run_id"].present? &&
            admission["provider_key"] == batch.external_account.provider_key
          raise InvalidEvidence, "Bootstrap evidence has inconsistent admission context"
        end
      end

      def validation_cache
        cache = ActiveSupport::IsolatedExecutionState[:provider_financial_identity_validation]
        return unless cache && !ApplicationRecord.connection.open_transactions.zero? &&
          cache[:database].equal?(ApplicationRecord.connection) && cache[:transaction].equal?(ApplicationRecord.current_transaction)

        cache
      end

      def captured_tuple(batch)
        [ batch.id, *IngestionBatch::CAPTURED_ATTRIBUTES.excluding("payload").map { |attribute| batch.public_send(attribute) } ]
      end

      def freeze_proof_input(value)
        case value
        when Hash
          value.each do |key, item|
            freeze_proof_input(key)
            freeze_proof_input(item)
          end
        when Array
          value.each { |item| freeze_proof_input(item) }
        end
        value.freeze
      end

      def require_transaction!
        raise ArgumentError, "Bootstrap capture requires a publication transaction" if ApplicationRecord.connection.open_transactions.zero?
      end

      def valid_identity?(identity)
        identity.is_a?(Hash) && identity.keys.sort == IDENTITY_KEYS.sort && identifier?(identity["external_id"]) &&
          identifier?(identity["input_external_id"]) && identity["input_occurrence"].is_a?(Integer) && identity["input_occurrence"] >= 0 &&
          %w[current retired_alias].include?(identity["role"]) && [ true, false ].include?(identity["pending"]) &&
          (identity["role"] != "retired_alias" || identity["pending"] == false)
      end

      def identifier?(value)
        value.is_a?(String) && value.present?
      end

      def find_identity!(payload, observation)
        admission = payload.fetch("admission")
        unless observation.external_account_id == admission["external_account_id"] && observation.family_id == admission["family_id"] &&
            observation.account_id == admission["account_id"] && observation.account_statement_id.nil?
          raise InvalidEvidence, "Bootstrap observation belongs to another source or account"
        end
        cached = validation_cache&.fetch(:entry)
        found = if cached && cached[:payload].equal?(payload)
          [ cached[:index][[ observation.kind, observation.external_id ]] ].compact
        else
          payload.fetch("plan").fetch("rows").filter_map do |row|
            next unless row.fetch("kind") == observation.kind
            identity = row.fetch("identities").find { |value| value.fetch("external_id") == observation.external_id }
            { row: row, identity: identity }.freeze if identity
          end
        end
        unless found.one? && found.first[:identity].values_at("input_external_id", "input_occurrence") ==
            [ observation.input_external_id, observation.input_occurrence ]
          raise InvalidEvidence, "Bootstrap has no exact observation identity"
        end
        found.first
      end

      def verify_plan_context!(plan, mapping, control, connection, external, link, account)
        expected = { "family_id" => account.family_id, "account_id" => account.id,
          "provider_connection_id" => connection.id, "external_account_id" => external.id,
          "account_provider_id" => link.id, "migration_mapping_id" => mapping.id,
          "legacy_account_id" => mapping.legacy_id, "archive_checksum" => mapping.source_checksum,
          "writer_epoch" => control.writer_epoch, "connection_writer_epoch" => connection.writer_epoch,
          "region" => connection.region, "environment" => connection.environment, "credential_revision" => connection.credential_revision }
        definition = Provider::AccountData::Registry.declared_adapter(control.provider_key).definition
        unless expected.all? { |key, value| plan[key] == value } && plan["source"] == definition.source &&
            (!plan.key?("provider_key") || plan["provider_key"] == control.provider_key) &&
            (!plan.key?("identity_namespace") || plan["identity_namespace"] == external.identity_namespace) &&
            (!plan.key?("account_provider_revision") || plan["account_provider_revision"] == link.lock_version)
          raise InvalidEvidence, "Financial identity plan has stale source context"
        end
      end

      def verify_legacy_archive!(mapping, control, manifest, link:, financial:)
        source = manifest.account_type.constantize.where(manifest.account_foreign_key => control.legacy_id).lock.find(mapping.legacy_id)
        archive = Provider::AccountData::MigrationCopier.new(provider_key: control.provider_key, legacy_item_id: control.legacy_id)
          .snapshot_for(mapping, max_bytes: MAX_ARCHIVE_BYTES, max_chunks: MAX_ARCHIVE_CHUNKS)
        Provider::AccountData::MigrationCopier.verify_account_binding!(archive: archive, link: link, financial: financial)
        unless archive["attributes"] == manifest.extract_account(source).source_attributes
          raise InvalidEvidence, "Legacy source changed after the verified copy"
        end
      end

      def verify_financial_rows!(rows, account)
        # Manual pending merges lock their two entries in pending/posting order.
        # Back off instead of waiting with a partial UUID-ordered lock set.
        entries = account.entries.where(id: rows.map { |row| row.fetch("entry_id") }).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
        raise InvalidEvidence, "A planned financial entry disappeared" unless entries.size == rows.size
        rows.group_by { |row| row.fetch("entryable_type") }.sort.each do |type, typed_rows|
          klass = type == "Transaction" ? Transaction : Trade
          ids = typed_rows.map { |row| entries.fetch(row.fetch("entry_id")).entryable_id }
          locked = klass.where(id: ids).order(:id).lock("FOR UPDATE NOWAIT").index_by(&:id)
          typed_rows.each do |row|
            entry = entries.fetch(row.fetch("entry_id"))
            entryable = locked[entry.entryable_id]
            snapshot = entryable && { "entry" => entry.attributes, "entryable" => entryable.attributes }
            unless entry.entryable_type == type && snapshot &&
                Provider::AccountData::MigrationValue.encode(snapshot) == row.fetch("financial_snapshot") &&
                Digest::SHA256.hexdigest(Provider::AccountData::MigrationValue.dump(snapshot)) == row.fetch("financial_checksum")
              raise InvalidEvidence, "Financial values or protections changed after planning"
            end
          end
        end
      end

      def resource(kind)
        { "transaction" => "transactions", "activity" => "activities" }.fetch(kind)
      end

      def bounded_serialization(value)
        serialized = Provider::AccountData::MigrationValue.dump(value)
        raise InvalidEvidence, "Financial identity evidence exceeds its capture bound" if serialized.bytesize > MAX_BYTES
        serialized
      end

      def signature(value)
        Ingestion::IdentitySigningKeys.configured.sign(bounded_serialization(value))
      end

      def immutable(value)
        Provider::AccountData::MigrationManifest.copy_value(value)
      end
  end
end
