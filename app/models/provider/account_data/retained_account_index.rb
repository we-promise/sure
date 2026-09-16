# Reverse ownership of each retained account archive, including superseded copy
# versions. A receipt records historical identity, never current writer authority.
class Provider::AccountData::RetainedAccountIndex
  Copier = Provider::AccountData::MigrationCopier
  Manifest = Provider::AccountData::MigrationManifest
  Receipt = ProviderMigrationAccountBinding
  CHECKSUM = /\Av1-[0-9a-f]{64}\z/
  UUID = Provider::AccountData::LegacyWriterFence::UUID
  Page = Data.define(:processed, :next_cursor, :complete)

  class << self
    def capture!(mapping:, source_checksum: nil)
      new(mapping, source_checksum: source_checksum).resolve(write: true)
    end

    def verify!(mapping:, source_checksum: nil)
      new(mapping, source_checksum: source_checksum).resolve(write: false)
    end

    def for_account(account)
      unless account.is_a?(Account) && account.id.to_s.match?(UUID) && account.family_id.to_s.match?(UUID)
        raise ArgumentError, "Expected a financial account identity"
      end
      Receipt.where(family_id: account.family_id, financial_account_id: account.id)
    end

    def assert_complete_for!(control)
      unless control.is_a?(ProviderMigrationControl) && control.persisted? && control.provider_connection_id
        raise ArgumentError, "Expected a mapped provider migration control"
      end
      if unindexed_chunks(family_id: control.family_id).where(provider_connection_id: control.provider_connection_id).exists?
        raise Copier::Conflict, "Retained account archive versions require reverse indexing"
      end
      true
    end

    # Every chunk needs membership in an exact indexed archive. Looking only for
    # first chunks would miss an orphan, an extra chunk, or a malformed sequence.
    # This is a coverage query, not a replacement for verify! before retirement.
    def unindexed_chunks(family_id:)
      archive_chunks(family_id: family_id).where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM provider_migration_account_bindings binding
          JOIN provider_migration_mappings mapping ON mapping.id = binding.provider_migration_mapping_id
          JOIN provider_migration_controls control ON control.id = mapping.provider_migration_control_id
          WHERE binding.family_id = ingestion_batches.family_id
            AND mapping.family_id = binding.family_id AND control.family_id = binding.family_id
            AND mapping.role = 'external_account'
            AND mapping.external_account_id = ingestion_batches.external_account_id
            AND control.provider_connection_id = ingestion_batches.provider_connection_id
            AND ingestion_batches.scope_key = mapping.legacy_type || ':' || mapping.legacy_id::text
            AND ingestion_batches.sequence >= 0 AND ingestion_batches.sequence < binding.chunk_count
            AND (ingestion_batches.sequence <> 0 OR ingestion_batches.id = binding.first_batch_id)
            AND ingestion_batches.idempotency_key = 'migration:' || control.id::text || ':' ||
              mapping.legacy_type || ':' || mapping.legacy_id::text || ':' || binding.source_checksum || ':' ||
              ingestion_batches.sequence::text
        )
      SQL
    end

    # Explicit, bounded backfill reads every archive version, not just each
    # mapping's current checksum. Missing roots remain visible as unindexed chunks.
    def backfill_page(family_id:, after_id: nil, limit: 25)
      unless family_id.is_a?(String) && family_id.match?(UUID) &&
          (after_id.nil? || (after_id.is_a?(String) && after_id.match?(UUID))) &&
          limit.is_a?(Integer) && (1..100).cover?(limit)
        raise ArgumentError, "Invalid retained account index page"
      end
      roots = archive_chunks(family_id: family_id).where(sequence: 0)
        .select(:id, :family_id, :external_account_id, :idempotency_key)
      roots = roots.where("id > ?", after_id) if after_id
      ids = roots.order(:id).limit(limit + 1).pluck(:id)
      ids.first(limit).each { |id| capture_root!(roots.find(id)) }
      Page.new(processed: ids.first(limit).size, next_cursor: ids.size > limit ? ids[limit - 1] : nil,
        complete: ids.size <= limit)
    rescue Copier::Conflict, Copier::Busy => error
      capture_backfill_failure(error, family_id: family_id, after_id: after_id)
      raise
    end

    private
      def archive_chunks(family_id:)
        scope = IngestionBatch.where(family_id: family_id, origin_kind: "migration", stream: "legacy_snapshot")
        # Only an exact, recognized item header can be excluded. Corrupt account
        # chunks must remain unresolved even after losing all account hints.
        scope.where(<<~SQL.squish, Manifest.all.map(&:item_type))
          NOT EXISTS (
            SELECT 1 FROM provider_migration_controls control
            WHERE ingestion_batches.external_account_id IS NULL
              AND control.family_id = ingestion_batches.family_id
              AND control.provider_connection_id = ingestion_batches.provider_connection_id
              AND control.legacy_type IN (?)
              AND ingestion_batches.scope_key = control.legacy_type || ':' || control.legacy_id::text
              AND ingestion_batches.idempotency_key ~ ('^migration:' || control.id::text || ':' ||
                control.legacy_type || ':' || control.legacy_id::text || ':v1-[0-9a-f]{64}:' ||
                ingestion_batches.sequence::text || '$')
          )
        SQL
      end

      def capture_root!(root)
        mapping = ProviderMigrationMapping.find_by!(family_id: root.family_id, role: "external_account",
          external_account_id: root.external_account_id)
        prefix = "migration:#{mapping.provider_migration_control_id}:#{mapping.legacy_type}:#{mapping.legacy_id}:"
        match = root.idempotency_key.match(/\A#{Regexp.escape(prefix)}(v1-[0-9a-f]{64}):0\z/)
        raise Copier::Conflict, "Retained account archive root has an invalid identity" unless match
        capture!(mapping: mapping, source_checksum: match[1])
      rescue ActiveRecord::RecordNotFound
        raise Copier::Conflict, "Retained account archive lost its mapping", cause: nil
      end

      def capture_backfill_failure(error, family_id:, after_id:)
        DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
          message: "Retained provider account indexing failed", source: name,
          family: Family.find_by(id: family_id),
          metadata: { family_id: family_id, after_id: after_id, error_class: error.class.name })
      rescue StandardError
        # Reporting must not replace the original archive refusal.
        nil
      end
  end

  def initialize(mapping, source_checksum: nil)
    unless mapping.is_a?(ProviderMigrationMapping) && mapping.persisted? && mapping.role == "external_account"
      raise Copier::Conflict, "Expected a retained external account mapping"
    end
    @mapping_id, @family_id, @external_id = mapping.id, mapping.family_id, mapping.external_account_id
    @control_id = mapping.provider_migration_control_id
    @source_checksum = source_checksum.nil? ? mapping.source_checksum : source_checksum
    unless @source_checksum.is_a?(String) && @source_checksum.match?(CHECKSUM)
      raise Copier::Conflict, "Invalid retained account archive checksum"
    end
  end

  def resolve(write:)
    ApplicationRecord.uncached do
      Receipt.transaction(requires_new: true) do
        # Copying locks its control before its target. Keep that order, and
        # refuse active edits instead of holding the target while waiting on it.
        control = ProviderMigrationControl.where(id: @control_id, family_id: @family_id)
          .lock("FOR SHARE NOWAIT").first!
        # The FK owner lock excludes new chunks during inventory/reconstruction;
        # locking existing chunks also excludes removal or payload replacement.
        external = ExternalAccount.where(id: @external_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
        mapping = ProviderMigrationMapping.where(id: @mapping_id, family_id: @family_id,
          provider_migration_control_id: control.id, role: "external_account", external_account_id: external.id)
          .lock("FOR UPDATE NOWAIT").first!
        manifest = Manifest.for(control.provider_key)
        unless control.family_id == @family_id && external.provider_connection_id == control.provider_connection_id &&
            external.provider_key == control.provider_key && mapping.legacy_type == manifest.account_type
          raise Copier::Conflict, "Retained account archive ownership differs"
        end
        prefix = "migration:#{control.id}:#{mapping.legacy_type}:#{mapping.legacy_id}:#{@source_checksum}"
        chunks = IngestionBatch.where(family_id: @family_id, origin_kind: "migration", stream: "legacy_snapshot",
          provider_connection_id: control.provider_connection_id,
          scope_key: "#{mapping.legacy_type}:#{mapping.legacy_id}")
          .where("idempotency_key LIKE ?", "#{prefix}:%").order(:sequence)
          .limit(Copier::RETAINED_ARCHIVE_CHUNKS + 1).select(:id, :sequence, :external_account_id, :idempotency_key)
          .lock("FOR SHARE NOWAIT").to_a
        if chunks.empty? || chunks.size > Copier::RETAINED_ARCHIVE_CHUNKS ||
            chunks.each_with_index.any? { |chunk, index| chunk.sequence != index || chunk.external_account_id != external.id || chunk.idempotency_key != "#{prefix}:#{index}" }
          raise Copier::Conflict, "Retained account archive chunk inventory differs"
        end
        copier = Copier.new(provider_key: control.provider_key, legacy_item_id: control.legacy_id)
        archive = copier.snapshot_for(mapping, source_checksum: @source_checksum,
          max_bytes: Copier::RETAINED_ROW_BYTES, max_chunks: Copier::RETAINED_ARCHIVE_CHUNKS)
        binding = verified_binding!(archive, mapping, control, manifest)
        attributes = {
          family_id: @family_id, provider_migration_mapping_id: mapping.id, source_checksum: @source_checksum,
          first_batch_id: chunks.first.id, chunk_count: chunks.size,
          binding_state: binding.fetch("financial_context") ? "linked" : "unlinked",
          financial_account_id: binding.dig("financial_context", "id"), account_provider_id: binding.dig("link", "id")
        }
        receipt = Receipt.find_by(provider_migration_mapping_id: mapping.id, source_checksum: @source_checksum)
        if receipt
          unless attributes.all? { |key, value| receipt.public_send(key) == value }
            raise Copier::Conflict, "Retained account reverse index differs from its verified archive"
          end
          receipt
        elsif write
          Receipt.create!(attributes)
        else
          raise Copier::Conflict, "Retained account archive requires reverse indexing"
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Copier::Conflict, "Retained account archive ownership is missing", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Copier::Busy, "Retained account archive is being changed; retry indexing", cause: nil
  rescue JSON::ParserError, ArgumentError, TypeError, EncodingError
    raise Copier::Conflict, "Retained account archive contains malformed data", cause: nil
  end

  private
    def verified_binding!(archive, mapping, control, manifest)
      unless archive.is_a?(Hash) && archive["format"] == Copier::SNAPSHOT_FORMAT &&
          archive["manifest_version"] == Manifest::VERSION && archive["provider_key"] == control.provider_key &&
          archive["source_type"] == mapping.legacy_type && archive["source_id"] == mapping.legacy_id &&
          archive["source_table"] == manifest.account_type.constantize.table_name &&
          archive["attributes"].is_a?(Hash) && archive["attributes"]["id"] == mapping.legacy_id &&
          archive["attributes"][manifest.account_foreign_key] == control.legacy_id
        raise Copier::Conflict, "Retained account archive does not describe its mapped source"
      end
      binding = Copier.account_binding!(archive: archive)
      return binding unless binding["financial_context"]

      financial, link = binding.values_at("financial_context", "link")
      unless financial["id"].is_a?(String) && financial["id"].match?(UUID) && financial["family_id"] == @family_id &&
          link["id"].is_a?(String) && link["id"].match?(UUID) && link["account_id"] == financial["id"] &&
          link["family_id"] == @family_id && link["provider_key"] == control.provider_key &&
          link["provider_type"] == mapping.legacy_type && link["provider_id"] == mapping.legacy_id &&
          link["external_account_id"] == @external_id
        raise Copier::Conflict, "Retained financial account binding has inconsistent ownership"
      end
      binding
    end
end
