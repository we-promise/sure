# Preserves source ownership after compatibility rows are removed. The witness is
# captured against live rows and an authenticated archive; it never confers
# financial authority or changes the original AccountProvider identity.
class Provider::AccountData::RetiredOwner
  class Conflict < Provider::AccountData::StaleWriter; end
  class TooLarge < Conflict; end
  class Busy < Provider::AccountData::IncompletePage; end

  FORMAT = "retained-provider-owner/v1".freeze
  MAX_MAPPINGS = 1_000
  MAX_BYTES = 32 * 1024 * 1024
  KEYS = %w[format family_id control_id provider_connection_id mapping_id role legacy_type legacy_id
    legacy_item_type legacy_item_id source_checksum copy_run_id copy_version].freeze
  BATCH_COLUMNS = %w[id family_id provider_connection_id external_account_id origin_kind stream scope_key
    sequence idempotency_key status writer_epoch].freeze
  Result = Data.define(:owner, :bytes)

  class << self
    # Preparation is a separate, explicit step before physical retirement. It
    # neither deletes compatibility rows nor marks the connection retired.
    def prepare!(control:, family:)
      unless ApplicationRecord.connection.open_transactions.zero?
        raise ArgumentError, "Retained owners require a legacy permit before a transaction"
      end
      unless control.is_a?(ProviderMigrationControl) && control.persisted? && family.is_a?(Family) &&
          family.persisted? && control.family_id == family.id
        raise Conflict, "Retained owners require their original family"
      end
      manifest = Provider::AccountData::MigrationManifest.for(control.provider_key)
      item = manifest.item_type.constantize.find_by!(id: control.legacy_id, family_id: family.id)
      Provider::AccountData::LegacyWriterFence.with_exclusive(item) do
        ApplicationRecord.uncached do
          ApplicationRecord.transaction(requires_new: true) do
            connection = ProviderConnection.where(id: control.provider_connection_id, family_id: family.id).lock("FOR UPDATE NOWAIT").first!
            current = ProviderMigrationControl.where(id: control.id, family_id: family.id).lock("FOR UPDATE NOWAIT").first!
            item.lock!("FOR UPDATE NOWAIT")
            if connection.lease_owner || connection.lease_expires_at || connection.lease_sync_id ||
                connection.syncs.incomplete.exists? || connection.provider_sync_generations.unfinished.exists? || item.syncs.incomplete.exists?
              raise Busy, "Finish outstanding sync work before retaining source ownership"
            end
            mappings = current.provider_migration_mappings.where(role: %w[connection external_account])
              .order(:id).limit(MAX_MAPPINGS + 1).lock("FOR UPDATE NOWAIT").to_a
            unless mappings.count { |mapping| mapping.role == "connection" } == 1
              raise Conflict, "Retained owners require one original connection mapping"
            end
            raise TooLarge, "Retained owner inventory exceeds its bound" if mappings.size > MAX_MAPPINGS
            remaining = MAX_BYTES
            mappings.each do |mapping|
              remaining -= new(mapping: mapping, family_id: family.id, max_bytes: remaining).capture!
            end
            mappings.map(&:id).freeze
          end
        end
      end
    rescue ActiveRecord::RecordNotFound
      raise Conflict, "Retained source ownership changed", cause: nil
    rescue ActiveRecord::LockWaitTimeout
      raise Busy, "Source ownership is being changed; retry after it finishes", cause: nil
    end

    def capture!(mapping:, family:)
      unless family.is_a?(Family) && family.persisted?
        raise ArgumentError, "Retained ownership requires an authorized family"
      end
      new(mapping: mapping, family_id: family.id).capture!
      mapping.reload.retained_owner
    end

    def resolve!(mapping:, family_id:, max_bytes: MAX_BYTES)
      ApplicationRecord.uncached { new(mapping: mapping, family_id: family_id, max_bytes: max_bytes).resolve! }
    end

    def lock_proof!(proof)
      unless ApplicationRecord.connection.transaction_open? && proof.is_a?(Hash) && proof["descriptor"].is_a?(Hash)
        raise Conflict, "Retained owner locks require their captured proof and transaction"
      end
      descriptor = proof.fetch("descriptor")
      ProviderConnection.where(id: descriptor.fetch("provider_connection_id")).lock("FOR UPDATE NOWAIT").first!
      ProviderMigrationControl.where(id: proof.fetch("control_id")).lock("FOR UPDATE NOWAIT").first!
      mapping = ProviderMigrationMapping.where(id: proof.fetch("mapping_id")).lock("FOR UPDATE NOWAIT").first!
      reader = new(mapping: mapping, family_id: descriptor.fetch("family_id"))
      reader.send(:validate_retired!)
      reader.send(:batch_scope).order(:id).limit(Provider::AccountData::RetainedRow::MAX_CHUNKS + 1)
        .select(:id).lock("FOR UPDATE NOWAIT").to_a
      unless reader.send(:proof) == proof
        raise Conflict, "Retained source proof changed before locking"
      end
      true
    rescue ActiveRecord::RecordNotFound, KeyError
      raise Conflict, "Retained source proof is incomplete", cause: nil
    rescue ActiveRecord::LockWaitTimeout
      raise Busy, "Retained source proof is busy; retry after it finishes", cause: nil
    end
  end

  def initialize(mapping:, family_id:, max_bytes: MAX_BYTES)
    unless mapping.is_a?(ProviderMigrationMapping) && mapping.persisted? && family_id.is_a?(String)
      raise Conflict, "Retained ownership requires a persisted source mapping"
    end
    raise TooLarge, "Retained source archives exceed their read bound" unless max_bytes.is_a?(Integer) && max_bytes.positive?
    @max_bytes = [ max_bytes, MAX_BYTES ].min
    @mapping = ProviderMigrationMapping.find_by!(id: mapping.id, family_id: family_id)
    @control = ProviderMigrationControl.find_by!(id: @mapping.provider_migration_control_id, family_id: family_id)
    @connection = ProviderConnection.find_by!(id: @control.provider_connection_id, family_id: family_id)
    @manifest = Provider::AccountData::MigrationManifest.for(@control.provider_key)
    validate_control!
    @reader = Provider::AccountData::RetainedRow.new(connection: @connection, provider_key: @manifest.provider_key, max_bytes: @max_bytes)
    @external = ExternalAccount.find(@mapping.external_account_id) if @mapping.role == "external_account"
    unless %w[connection external_account].include?(@mapping.role) && descriptor.fetch("mapping_id") == @mapping.id &&
        @mapping.provider_authorization_id.nil? &&
        (@mapping.role == "connection" ? @mapping.external_account_id.nil? : @mapping.provider_connection_id.nil?)
      raise Conflict, "Retained ownership has no exact source mapping"
    end
  rescue ActiveRecord::RecordNotFound, KeyError, Provider::AccountData::StaleWriter => error
    raise error if error.is_a?(Conflict)
    raise Conflict, "Retained source ownership is missing or changed", cause: nil
  end

  def capture!
    raise ArgumentError, "Capture requires an existing transaction" unless ApplicationRecord.connection.transaction_open?
    item = manifest.item_type.constantize.find_by!(id: control.legacy_id, family_id: connection.family_id)
    Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
    connection.lock!("FOR UPDATE NOWAIT")
    control.lock!("FOR UPDATE NOWAIT")
    mapping.lock!("FOR UPDATE NOWAIT")
    item.lock!("FOR UPDATE NOWAIT")
    validate_control!
    @external&.lock!("FOR UPDATE NOWAIT")
    @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: manifest.provider_key, max_bytes: @max_bytes)
    unless descriptor.fetch("mapping_id") == mapping.id
      raise Conflict, "Retained ownership changed its source mapping"
    end
    if mapping.role == "external_account"
      source = manifest.account_type.constantize.where(id: mapping.legacy_id).lock("FOR UPDATE NOWAIT").first!
      raise Conflict, "Retained source changed its original parent" unless source.read_attribute(manifest.account_foreign_key) == item.id
    end
    batch_scope.order(:id).limit(Provider::AccountData::RetainedRow::MAX_CHUNKS + 1)
      .select(:id).lock("FOR UPDATE NOWAIT").to_a
    authenticated_row!
    expected = projection
    if mapping.retained_owner.nil?
      mapping.update!(retained_owner: expected)
    elsif mapping.retained_owner != expected
      raise Conflict, "Retained owner witness differs from the original source"
    end
    @bytes
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Retained ownership must be captured while its source exists", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Source ownership is busy; retry after it finishes", cause: nil
  end

  def resolve!
    validate_retired!
    before = proof
    authenticated_row!
    current = self.class.new(mapping: mapping, family_id: connection.family_id, max_bytes: @max_bytes)
    current.send(:validate_retired!)
    raise Conflict, "Retained owner changed while reading its archive" unless current.send(:proof) == before
    owner = { "id" => mapping.legacy_id, "type" => mapping.legacy_type, "row_version" => nil, "tuple_version" => nil,
      "retired_owner" => before }
    owner[mapping.role == "connection" ? "family_id" : "item_id"] = mapping.role == "connection" ? connection.family_id : control.legacy_id
    Result.new(owner: Provider::AccountData::MigrationManifest.copy_value(owner), bytes: @bytes).freeze
  end

  private
    attr_reader :mapping, :control, :connection, :manifest

    def validate_control!
      receipt = control.audit_results["native_cutover"]
      unless control.native_owned? && control.legacy_type == manifest.item_type && connection.provider_key == control.provider_key &&
          receipt.is_a?(Hash) && receipt["format"] == Provider::AccountData::MigrationCutover::FORMAT &&
          receipt["connection_id"] == connection.id && receipt["writer_epoch"] == 1 && control.writer_epoch == 1 &&
          connection.writer_epoch >= 1 && receipt["preparation_run_id"].present? &&
          receipt["preparation_run_id"] == control.preparation_state["run_id"] &&
          receipt["copy_run_id"] == control.high_water_mark["copy_run_id"] &&
          receipt["copy_run_id"] == control.audit_results["copy_run_id"] &&
          Sync.exists?(id: receipt["sync_id"], syncable_type: "ProviderConnection", syncable_id: connection.id)
        raise Conflict, "Retained ownership requires the original native cutover"
      end
    end

    def descriptor
      @external ? @reader.account_descriptor(@external) : @reader.item_descriptor
    end

    def projection
      { "format" => FORMAT, "family_id" => connection.family_id, "control_id" => control.id,
        "provider_connection_id" => connection.id, "mapping_id" => mapping.id, "role" => mapping.role,
        "legacy_type" => mapping.legacy_type, "legacy_id" => mapping.legacy_id,
        "legacy_item_type" => control.legacy_type, "legacy_item_id" => control.legacy_id,
        "source_checksum" => mapping.source_checksum, "copy_run_id" => control.high_water_mark.fetch("copy_run_id"),
        "copy_version" => control.copy_version }
    end

    def validate_retired!
      unless control.retired? && mapping.retained_owner == projection
        raise Conflict, "Missing source has no recorded retirement witness"
      end
      model = (mapping.role == "connection" ? manifest.item_type : manifest.account_type).constantize
      raise Conflict, "Present sources cannot be replaced by archived ownership" if model.exists?(id: mapping.legacy_id)
    end

    def batch_scope
      prefix = "migration:#{control.id}:#{mapping.legacy_type}:#{mapping.legacy_id}:#{mapping.source_checksum}:"
      IngestionBatch.where(family_id: connection.family_id, provider_connection_id: connection.id,
        origin_kind: "migration", stream: "legacy_snapshot", scope_key: "#{mapping.legacy_type}:#{mapping.legacy_id}")
        .where("idempotency_key LIKE ?", "#{prefix}%")
    end

    def headers
      columns = BATCH_COLUMNS + %w[row_version tuple_version payload_checksum stored_bytes]
      rows = batch_scope.order(:sequence, :id).limit(Provider::AccountData::RetainedRow::MAX_CHUNKS + 1)
        .pluck(*BATCH_COLUMNS, Arel.sql("xmin::text"), Arel.sql("ctid::text"),
          Arel.sql("md5(payload::text)"), Arel.sql("COALESCE(octet_length(payload::text), 0)"))
        .map { |values| columns.zip(values).to_h }
      raise Conflict, "Retained source archive is missing" if rows.empty?
      if rows.size > Provider::AccountData::RetainedRow::MAX_CHUNKS ||
          rows.sum { |row| row.fetch("stored_bytes") } > @max_bytes * 4 + rows.size * 4_096
        raise TooLarge, "Retained source archive exceeds its read bound"
      end
      rows.each_with_index do |row, index|
        unless row["sequence"] == index && row["external_account_id"] == mapping.external_account_id
          raise Conflict, "Retained source archive changed its owner or sequence"
        end
      end
      rows
    end

    def proof
      { "mapping_id" => mapping.id, "control_id" => control.id, "descriptor" => descriptor,
        "witness" => mapping.retained_owner, "batches" => headers }
    end

    def authenticated_row!
      before = headers
      result = @external ? @reader.account(@external) : @reader.item
      @bytes = result.byte_size
      raise TooLarge, "Retained source archive exceeds its read bound" if @bytes > @max_bytes
      raise Conflict, "Retained source archive changed during capture" unless headers == before
      result
    rescue Provider::AccountData::RetainedRow::TooLarge
      raise TooLarge, "Retained source archive exceeds its read bound", cause: nil
    rescue Provider::AccountData::StaleWriter => error
      raise error if error.is_a?(Conflict)
      raise Conflict, "Retained source archive is missing or unauthenticated", cause: nil
    end
end
