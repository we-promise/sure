require "json"

# Read only this sync's captured inventory. A completed prior export is never a
# fallback for a new sync, and disagreeing captures cannot pick a silent winner.
class Provider::AccountData::Ibkr::Archive
  MAX_BATCHES = 1_024
  MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
  # Encrypted JSON includes the ciphertext's base64 envelope. Check its size in
  # PostgreSQL before loading it, then bound decoded canonical JSON separately.
  MAX_STORED_BYTES = 96 * 1024 * 1024

  def self.build(connection:, sync:, observed_at:)
    new(connection: connection, sync: sync, observed_at: observed_at).build
  end

  def self.resolve(connection:, sync:, observed_at:, source_batch_id:)
    new(connection: connection, sync: sync, observed_at: observed_at).resolve(source_batch_id)
  end

  def initialize(connection:, sync:, observed_at:)
    unless connection.provider_key == "ibkr" && sync&.persisted? && sync.syncable_type == "ProviderConnection" &&
        sync.syncable_id == connection.id && observed_at.to_time == sync.created_at.to_time
      raise Provider::AccountData::InvalidResponse, "IBKR export requires its original provider sync"
    end
    @connection, @sync = connection, sync
    @scope = Provider::AccountData::Ibkr::Export.scope(family_id: connection.family_id, provider_connection_id: connection.id,
      sync_id: sync.id, observed_at: observed_at, timezone: connection.family.timezone)
  end

  def build
    inventory = inventory_batches.order(:sequence, :id).limit(MAX_BATCHES + 1).pluck(:id, Arel.sql("octet_length(payload)"))
    raise Provider::AccountData::IncompletePage, "IBKR inventory archive exceeds its reviewed page bound" if inventory.size > MAX_BATCHES
    if inventory.sum { |_id, bytes| bytes.to_i } > MAX_STORED_BYTES
      raise Provider::AccountData::IncompletePage, "IBKR inventory archive exceeds its stored byte budget"
    end
    reference, artifact, source_id = nil, nil, nil
    decoded_bytes = 0
    artifact_batch_ids = []
    inventory.each do |id, _bytes|
      batch = inventory_batches.find(id)
      decoded_bytes += JSON.generate(batch.payload).bytesize
      if decoded_bytes > MAX_ARCHIVE_BYTES
        raise Provider::AccountData::IncompletePage, "IBKR inventory archive exceeds its decoded byte budget"
      end
      page = read_page(batch)
      value = page.evidence["ibkr_export"]
      if value.nil?
        # Request/poll status XML is not a Flex export.
        unless page.records.empty? && !page.complete? && page.progress_cursor &&
            page.warnings.any? { |warning| warning["code"] == "statement_pending" } && !page.evidence["statement_sha256"]
          raise ArgumentError
        end
        next
      end
      Provider::AccountData::Ibkr::Export.validate_reference!(value, expected_scope: @scope)
      current_reference = value.except("response_xml")
      raise ArgumentError if reference && reference != current_reference
      reference ||= current_reference
      if value.key?("response_xml")
        if artifact
          # Matching bytes and the already-validated reference need no second
          # XML parse. Still count every duplicate against the archive budget.
          raise ArgumentError unless value["response_xml"] == artifact.statement.xml
        else
          artifact = Provider::AccountData::Ibkr::Export.load(value, expected_scope: @scope)
          source_id = batch.id
        end
        artifact_batch_ids << batch.id
      end
    end
    raise Provider::AccountData::IncompletePage, "The original IBKR export artifact is missing" if reference && !artifact
    @artifact, @artifact_batch_ids = artifact, artifact_batch_ids
    { scope: @scope, export: artifact&.payload, source_batch_id: source_id }
  rescue ArgumentError, KeyError, TypeError
    raise Provider::AccountData::InvalidResponse, "IBKR captured exports disagree with this sync", cause: nil
  end

  def resolve(source_batch_id)
    build
    raise ArgumentError unless @artifact_batch_ids.include?(source_batch_id)
    batch = inventory_batches.find(source_batch_id)
    raise ArgumentError unless %w[captured applied].include?(batch.status)
    { batch: batch, export: @artifact }
  rescue ArgumentError, KeyError, TypeError, ActiveRecord::RecordNotFound
    raise Provider::AccountData::InvalidResponse, "IBKR export reference does not belong to this sync", cause: nil
  end

  private
    def inventory_batches
      @connection.ingestion_batches.where(family_id: @connection.family_id, sync_id: @sync.id, origin_kind: "provider",
        stream: "accounts", scope_key: "connection", external_account_id: nil)
    end

    def read_page(batch)
      raise ArgumentError unless %w[captured applied].include?(batch.status) && batch.mode == "snapshot"
      page = Ingestion::Codec.load(batch.payload)
      raise ArgumentError unless page.mode == "snapshot" && page.complete? == batch.complete? && page.records.all? { |record| record.kind == "account" }
      if page.evidence["ibkr_export"]
        reference = page.evidence.fetch("ibkr_export")
        Provider::AccountData::Ibkr::Export.validate_reference!(reference, expected_scope: @scope)
        valid_records = page.records.all? do |record|
          metadata = (record[:metadata] || {}).with_indifferent_access
          metadata[:statement_sha256] == reference.fetch("statement_sha256") && metadata[:statement_sync_id] == @sync.id &&
            metadata[:statement_observed_on] == @scope.fetch("observed_on")
        end
        raise ArgumentError unless valid_records
      end
      page
    end
end
