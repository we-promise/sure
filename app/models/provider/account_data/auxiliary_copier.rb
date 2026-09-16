require "base64"
require "digest"
require "openssl"

# A bounded copy of explicitly reviewed legacy logo attachments. Existing
# Active Storage rows and objects remain in place; only a second attachment to
# the same blob and encrypted migration evidence are created.
class Provider::AccountData::AuxiliaryCopier
  class Conflict < StandardError; end
  class SourceChanged < Conflict; end

  FORMAT = "provider-logo-auxiliary/v1".freeze
  STREAM = "legacy_logo_auxiliary".freeze
  MAX_BYTES = 32 * 1024 * 1024
  MAX_MANIFEST_BYTES = 256 * 1024
  MAX_STATE_BYTES = 1024 * 1024
  RETAINED_FORMAT = "provider-retained-logo-auxiliary/v1".freeze
  ATTACHMENT_COLUMNS = %w[id name record_type record_id blob_id created_at].freeze
  BLOB_COLUMNS = %w[id key filename content_type metadata service_name byte_size checksum created_at].freeze
  COPY_STATES = %w[copying shadow failed quiescing].freeze
  SUPPORTED_PROVIDER_KEYS = %w[akahu binance brex coinbase coinstats enable_banking ibkr indexa_capital kraken lunchflow
    mercury monobank plaid questrade redbark simplefin snaptrade sophtron trading212 up].freeze
  PROVIDER_KEYS = (SUPPORTED_PROVIDER_KEYS - [ "ibkr" ]).freeze
  BATCH_KEY_PREFIX = "provider-logo-auxiliary".freeze
  KEY_SALT = "provider-logo-auxiliary-manifest-v1".freeze

  include Retirement

  # Existing IBKR archives keep their original formats, stream, keys and signer
  # salt. Neither entrypoint reinterprets an archive belonging to the other.
  def self.for(control:, **options)
    klass = control.provider_key == "ibkr" ? Provider::AccountData::Ibkr::AuxiliaryCopier : self
    klass.new(control: control, **options)
  end

  def self.supports?(provider_key)
    SUPPORTED_PROVIDER_KEYS.include?(provider_key)
  end

  def self.stream_for(provider_key)
    raise ArgumentError, "Provider has no reviewed logo scope" unless supports?(provider_key)
    provider_key == "ibkr" ? Provider::AccountData::Ibkr::AuxiliaryCopier::STREAM : STREAM
  end

  Receipt = Data.define(:phase, :checkpoint_id, :context, :copied_chunks, :verified_chunks) do
    def complete?
      phase == "complete"
    end

    def inspect
      "#<#{self.class.name} phase=#{phase}>"
    end
  end
  VerificationPage = Data.define(:context, :rows, :next_cursor, :complete)

  def initialize(control:, chunks_per_run: 4, chunk_bytes: 128 * 1024)
    unless control.is_a?(ProviderMigrationControl) && control.persisted? && self.class::PROVIDER_KEYS.include?(control.provider_key)
      raise ArgumentError, "Expected a reviewed logo migration control"
    end
    @manifest = Provider::AccountData::MigrationManifest.for(control.provider_key)
    raise ArgumentError, "Unexpected logo source type" unless control.legacy_type == @manifest.item_type
    @control = control
    @chunks_per_run, @chunk_bytes = Integer(chunks_per_run), Integer(chunk_bytes)
    raise ArgumentError unless (1..8).cover?(@chunks_per_run) && (1024..1024 * 1024).cover?(@chunk_bytes)
  end

  # Each call reads at most chunks_per_run bounded byte ranges. A separate pass
  # compares the source bytes again before linking the target and sealing proof.
  def run
    fenced do
      state = guarded { initialize_or_validate_checkpoint! }
      return @checkpoint if state.fetch("phase") == "complete"
      phase = state.fetch("phase")
      start = state.fetch(phase == "copy" ? "copied_chunks" : "verified_chunks")
      finish = [ start + @chunks_per_run, state.fetch("chunks") ].min
      (start...finish).each do |index|
        bytes = read_source_chunk(state, index)
        guarded do
          validate_source!(state)
          if phase == "copy"
            capture_chunk!(state, index, bytes)
            @checkpoint.update!(state: @checkpoint.state.merge("copied_chunks" => index + 1))
          else
            raise Conflict, "Provider logo bytes changed after capture" unless archived_chunk(state, index) == bytes
            @checkpoint.update!(state: @checkpoint.state.merge("verified_chunks" => index + 1))
          end
        end
      end
      guarded do
        state = @checkpoint.state
        validate_source!(state)
        if state.fetch("phase") == "copy" && state.fetch("copied_chunks") == state.fetch("chunks")
          @checkpoint.update!(state: state.merge("phase" => "verify"))
        elsif state.fetch("phase") == "verify" && state.fetch("verified_chunks") == state.fetch("chunks")
          finalize!(state)
        end
      end
      @checkpoint.reload
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Connection-scoped child of quiesced preparation. The original row copy is
  # pinned before the first byte; resumed workers never replace an old archive.
  # Storage still runs outside the short publication transactions.
  def run_retained(family:, expected_context: nil)
    authorize_family!(family)
    @retained_mode = true
    fenced do
      guarded do
        state = initialize_or_validate_checkpoint!
        if expected_context && retained_context(state) != expected_context
          raise Conflict, "Provider auxiliary receipt belongs to another retained copy"
        end
      end
      run
      guarded do
        state = initialize_or_validate_checkpoint!
        Receipt.new(phase: state.fetch("phase").dup.freeze, checkpoint_id: @checkpoint.id,
          context: immutable(retained_context(state)), copied_chunks: state.fetch("copied_chunks"), verified_chunks: state.fetch("verified_chunks"))
      end
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  ensure
    @retained_mode = false
  end

  # Rechecks completed original evidence without resetting its progress. The
  # caller retains every returned page; complete means the end of enumeration,
  # never authority to activate a provider or assume cross-call quiescence.
  def verify_retained_page(family:, cursor: nil, limit: 4)
    authorize_family!(family)
    raise ArgumentError, "Verification limit must be between one and eight" unless limit.is_a?(Integer) && (1..8).cover?(limit)
    @retained_mode = true
    fenced do
      state, context, start = guarded do
        raise Conflict, "Retained Provider auxiliary checkpoint is missing" unless @checkpoint
        state = initialize_or_validate_checkpoint!
        raise Conflict, "Complete retained auxiliary copying before verification" unless state.fetch("phase") == "complete"
        context = verification_context(state, limit: limit)
        first = if cursor
          unless cursor.is_a?(Hash) && cursor.except("next_chunk") == context && cursor["next_chunk"].is_a?(Integer) &&
              cursor["next_chunk"].positive? && cursor["next_chunk"] < state.fetch("chunks")
            raise Conflict, "Provider auxiliary verification continuation changed"
          end
          cursor.fetch("next_chunk")
        else
          0
        end
        [ state.deep_dup, context, first ]
      end
      finish = [ start + limit, state.fetch("chunks") ].min
      rows = (start...finish).map do |index|
        bytes = read_source_chunk(state, index)
        guarded do
          validate_retained_snapshot!(state)
          raise Conflict, "Provider logo bytes changed after capture" unless archived_chunk(state, index) == bytes
        end
        { "index" => index, "byte_size" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
      end
      guarded do
        validate_retained_snapshot!(state)
        if finish == state.fetch("chunks") && verify_archive!(state) != state.fetch("content_sha256")
          raise Conflict, "Provider retained archive checksum changed"
        end
      end
      complete = finish == state.fetch("chunks")
      VerificationPage.new(context: immutable(context), rows: immutable(rows),
        next_cursor: complete ? nil : immutable(context.merge("next_chunk" => finish)), complete: complete)
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  ensure
    @retained_mode = false
  end

  # Seal the database side of a completed byte sweep inside the caller's final
  # cutover transaction. The exclusive permit must span that earlier sweep and
  # this check; this method never reads remote storage or grants activation.
  def verify_retained_context!(family:, expected_context:)
    authorize_family!(family)
    raise Provider::AccountData::MigrationManifest::EncryptionRequired, "Configure encryption before auxiliary verification" unless ActiveRecordEncryptionConfig.ready?
    unless ApplicationRecord.connection.transaction_open?
      raise ArgumentError, "Final auxiliary verification requires a database transaction"
    end
    item = item_class.find_by!(id: @control.legacy_id, family_id: @control.family_id)
    Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
    unless expected_context.is_a?(Hash) && expected_context["limit"].is_a?(Integer) && (1..8).cover?(expected_context["limit"])
      raise Conflict, "Provider auxiliary verification context changed"
    end
    @retained_mode = true
    guarded do
      raise Conflict, "Retained Provider auxiliary checkpoint is missing" unless @checkpoint
      state = initialize_or_validate_checkpoint!
      raise Conflict, "Complete retained auxiliary copying before verification" unless state.fetch("phase") == "complete"
      context = verification_context(state, limit: expected_context.fetch("limit"))
      raise Conflict, "Provider auxiliary verification context changed" unless context == expected_context
      unless verify_archive!(state, lock: true) == state.fetch("content_sha256")
        raise Conflict, "Provider retained archive checksum changed"
      end
      immutable(context)
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  ensure
    @retained_mode = false
  end

  # Reverification uses the existing immutable capture and does not silently
  # recopy changed source bytes. The quiesced final-copy coordinator can call it
  # while reentering its same-item exclusive legacy fence, outside a transaction.
  def restart_verification!
    fenced do
      guarded do
        state = initialize_or_validate_checkpoint!
        raise Conflict, "Finish copying the logo before reverification" unless state.fetch("copied_chunks") == state.fetch("chunks")
        @checkpoint.update!(state: state.merge("phase" => "verify", "verified_chunks" => 0, "verified_at" => nil))
      end
      @checkpoint
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Read-only recovery of exact bytes. Authorize the control's family before
  # exposing these values. Validate the entire archive before yielding any bytes.
  def each_archived_chunk
    return enum_for(:each_archived_chunk) unless block_given?
    @control.reload
    @checkpoint = checkpoint_scope.find_by!(scope_key: scope_key)
    validate_checkpoint!
    state = @checkpoint.state
    validate_state!(state)
    raise Conflict, "Provider logo archive has not been verified" unless state.fetch("phase") == "complete"
    sha256 = verify_archive!(state)
    raise Conflict, "Provider logo archive checksum changed" unless sha256 == state.fetch("content_sha256")
    state.fetch("chunks").times { |index| yield archived_chunk(state, index) }
    nil
  end

  private
    def item_class
      @manifest.item_type.constantize
    end

    def account_class
      @manifest.account_type.constantize
    end

    def fenced
      raise Provider::AccountData::MigrationManifest::EncryptionRequired, "Configure encryption before auxiliary copy" unless ActiveRecordEncryptionConfig.ready?
      unless ApplicationRecord.connection.open_transactions.zero?
        raise ArgumentError, "Auxiliary storage reads must run outside a database transaction"
      end
      item = item_class.find_by!(id: @control.legacy_id, family_id: @control.family_id)
      Provider::AccountData::LegacyWriterFence.with_exclusive(item) { yield }
    end

    def guarded
      @control.with_lock do
        @connection = @control.provider_connection
        unless COPY_STATES.include?(@control.state) && @connection && @connection.provider_key == @manifest.provider_key && @connection.family_id == @control.family_id
          raise Conflict, "Provider auxiliary copy requires a pre-cutover mapped connection"
        end
        @connection.lock!
        unless @connection.disabled? && @connection.writer_epoch.zero? && @control.writer_epoch.zero? && @connection.lease_owner.nil? &&
            @connection.credential_state.blank? && @connection.syncs.none? && @connection.ingestion_batches.where.not(origin_kind: "migration").none?
          raise Conflict, "Provider auxiliary target must remain unused and disabled"
        end
        mapping = @control.provider_migration_mappings.find_by!(role: "connection", legacy_type: @manifest.item_type, legacy_id: @control.legacy_id)
        raise Conflict, "Provider auxiliary target differs from its connection mapping" unless mapping.provider_connection_id == @connection.id
        scope = checkpoint_scope.where(scope_key: scope_key)
        bytes = scope.pick(Arel.sql("octet_length(state)"))
        raise Conflict, "Provider auxiliary progress exceeds its bound" if bytes && bytes > MAX_STATE_BYTES * 2
        @checkpoint = scope.where("octet_length(state) <= ?", MAX_STATE_BYTES * 2).first
        @checkpoint&.lock!
        checkpoint_ids = @connection.provider_sync_checkpoints.where(stream: self.class::STREAM).limit(2).pluck(:id)
        unless checkpoint_ids.empty? || checkpoint_ids == [ @checkpoint&.id ]
          raise Conflict, "Provider auxiliary checkpoint inventory changed"
        end
        if @retained_mode
          page = Provider::AccountData::MigrationCopier.new(provider_key: @manifest.provider_key, legacy_item_id: @control.legacy_id)
            .verify_retained_quiesced_page(family: @control.family, limit: 1)
          @current_copy_context = page.context.except("page_size")
        elsif @checkpoint&.state&.key?("retained_copy_context")
          raise Conflict, "Use the retained auxiliary API for this copy-bound receipt"
        end
        yield
      end
    end

    def checkpoint_scope
      ProviderSyncCheckpoint.where(provider_connection_id: @control.provider_connection_id, family_id: @control.family_id, stream: self.class::STREAM)
    end

    def scope_key
      "#{@manifest.item_type}:#{@control.legacy_id}:logo"
    end

    def source_manifest(lock: false)
      unless ActiveStorage::Attachment.column_names.sort == ATTACHMENT_COLUMNS.sort && ActiveStorage::Blob.column_names.sort == BLOB_COLUMNS.sort &&
          item_class.reflect_on_all_attachments.map(&:name).map(&:to_s).sort == [ "logo" ] && account_class.reflect_on_all_attachments.empty?
        raise Conflict, "Provider auxiliary schema changed and needs a reviewed disposition"
      end
      item = item_class.where(id: @control.legacy_id, family_id: @control.family_id)
      item = item.lock if lock
      item.first!
      attachments = ActiveStorage::Attachment.where(record_type: @manifest.item_type, record_id: @control.legacy_id, name: "logo").order(:id)
      attachments = attachments.lock if lock
      rows = attachments.limit(2).to_a
      raise Conflict, "Provider has multiple logo attachments" if rows.size > 1
      attachment = rows.first
      blob = if attachment
        scope = ActiveStorage::Blob.where(id: attachment.blob_id)
        size_sql = "COALESCE(octet_length(metadata::text), 0) + octet_length(key) + octet_length(filename) + octet_length(service_name) + COALESCE(octet_length(content_type), 0)"
        metadata_bytes = scope.pick(Arel.sql(size_sql))
        raise Conflict, "Provider logo metadata exceeds its reviewed bound" if metadata_bytes.to_i > MAX_MANIFEST_BYTES
        scope = scope.where("#{size_sql} <= ?", MAX_MANIFEST_BYTES)
        scope = scope.lock("FOR SHARE") if lock
        scope.first!
      end
      if blob && (!blob.byte_size.is_a?(Integer) || !(0..MAX_BYTES).cover?(blob.byte_size) || blob.checksum.blank?)
        raise Conflict, "Provider logo exceeds its reviewed size or has no storage checksum"
      end
      manifest = { "family_id" => @control.family_id, "control_id" => @control.id, "provider_connection_id" => @control.provider_connection_id,
        "source_type" => @manifest.item_type, "source_id" => @control.legacy_id,
        "attachment" => attachment&.attributes&.slice(*ATTACHMENT_COLUMNS), "blob" => blob&.attributes&.slice(*BLOB_COLUMNS) }
      if Provider::AccountData::MigrationValue.dump(manifest).bytesize > MAX_MANIFEST_BYTES
        raise Conflict, "Provider logo metadata exceeds its reviewed bound"
      end
      manifest
    end

    def initialize_or_validate_checkpoint!
      if @checkpoint
        validate_checkpoint!
        validate_state!(@checkpoint.state)
        validate_source!(@checkpoint.state)
        validate_target!(@checkpoint.state) if @checkpoint.state.fetch("phase") == "complete"
        if @retained_mode && @checkpoint.state["retained_copy_context"] != @current_copy_context
          raise Conflict, "Provider auxiliary archive has no matching original copy binding; explicit reconciliation is required"
        end
        if @checkpoint.state.fetch("phase") != "complete" && financial_identity_progress?
          raise Conflict, "Finish auxiliary capture before financial identity publication"
        end
        return @checkpoint.state
      end
      if @connection.ingestion_batches.where(stream: self.class::STREAM).exists?
        raise Conflict, "Retained Provider auxiliary batches require their original checkpoint"
      end
      raise Conflict, "Auxiliary capture must precede financial identity publication" if financial_identity_progress?
      manifest = source_manifest(lock: true)
      total_bytes = manifest["blob"]&.fetch("byte_size") || 0
      state = { "format" => self.class::FORMAT, "source_digest" => fingerprint(manifest),
        "manifest" => Provider::AccountData::MigrationValue.encode(manifest), "chunk_bytes" => @chunk_bytes,
        "chunks" => (total_bytes + @chunk_bytes - 1) / @chunk_bytes, "copied_chunks" => 0, "verified_chunks" => 0, "phase" => "copy" }
      state["retained_copy_context"] = @current_copy_context if @retained_mode
      @checkpoint = checkpoint_scope.create!(provider_connection: @connection, scope_key: scope_key, schema_version: 1, state: state)
      state
    end

    def validate_state!(state)
      raise Conflict, "Unknown provider auxiliary archive" unless state.is_a?(Hash) && state["format"] == self.class::FORMAT && %w[copy verify complete].include?(state["phase"])
      size, chunks = state.values_at("chunk_bytes", "chunks")
      unless size.is_a?(Integer) && (1024..1024 * 1024).cover?(size) && chunks.is_a?(Integer) && (0..MAX_BYTES / size + 1).cover?(chunks)
        raise Conflict, "Invalid Provider auxiliary chunk bounds"
      end
      unless %w[copied_chunks verified_chunks].all? { |key| state[key].is_a?(Integer) && (0..chunks).cover?(state[key]) }
        raise Conflict, "Invalid Provider auxiliary progress"
      end
      if (state["phase"] == "copy" && state["verified_chunks"] != 0) ||
          (state["phase"] != "copy" && state["copied_chunks"] != chunks) ||
          (state["phase"] == "complete" && (state["verified_chunks"] != chunks || !state["content_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) || state["verified_at"].blank?))
        raise Conflict, "Provider auxiliary phase does not match its durable progress"
      end
      manifest = Provider::AccountData::MigrationValue.decode(state.fetch("manifest"))
      unless manifest.is_a?(Hash) && manifest.values_at("family_id", "control_id", "provider_connection_id", "source_type", "source_id") ==
          [ @control.family_id, @control.id, @control.provider_connection_id, @manifest.item_type, @control.legacy_id ] && fingerprint(manifest) == state["source_digest"]
        raise Conflict, "Provider auxiliary provenance changed"
      end
      bytes = manifest["blob"]&.fetch("byte_size") || 0
      raise Conflict, "Provider auxiliary size changed" unless bytes.is_a?(Integer) && (0..MAX_BYTES).cover?(bytes) && chunks == (bytes + size - 1) / size
      manifest
    end

    def validate_checkpoint!
      unless @checkpoint.schema_version == 1 && @checkpoint.external_account_id.nil? && @checkpoint.provider_authorization_id.nil? &&
          @checkpoint.ingestion_batch_id.nil? && @checkpoint.provider_sync_generation_id.nil? && @checkpoint.cursor.nil? && @checkpoint.covered_through.nil?
        raise Conflict, "Provider auxiliary checkpoint has unrelated execution context"
      end
    end

    def validate_source!(state)
      manifest = validate_state!(state)
      unless source_manifest(lock: true) == manifest
        raise SourceChanged, "Provider logo metadata or attachment changed; retain this capture for review"
      end
    end

    def read_source_chunk(state, index)
      manifest = validate_state!(state)
      blob = ActiveStorage::Blob.select(:id, :key, :service_name).find(manifest.fetch("blob").fetch("id"))
      start = index * state.fetch("chunk_bytes")
      length = [ state.fetch("chunk_bytes"), manifest.fetch("blob").fetch("byte_size") - start ].min
      bytes = blob.download_chunk(start...(start + length))
      raise Conflict, "Incomplete Provider logo storage response" unless bytes.is_a?(String) && bytes.bytesize == length
      bytes.b
    end

    def batch_key(state, index)
      "#{self.class::BATCH_KEY_PREFIX}:#{@control.id}:#{state.fetch('source_digest')}:#{state.fetch('chunk_bytes')}:#{index}"
    end

    def capture_chunk!(state, index, bytes)
      payload = { "format" => self.class::FORMAT, "source_digest" => state.fetch("source_digest"), "index" => index,
        "chunks" => state.fetch("chunks"), "chunk_bytes" => state.fetch("chunk_bytes"), "data" => Base64.strict_encode64(bytes) }
      batch = @connection.ingestion_batches.find_or_initialize_by(idempotency_key: batch_key(state, index))
      if batch.persisted?
        raise Conflict, "Captured Provider logo chunk differs" unless archived_chunk(state, index) == bytes
      else
        batch.assign_attributes(family: @control.family, origin_kind: "migration", stream: self.class::STREAM, scope_key: scope_key,
          sequence: index, schema_version: 1, mode: "unknown", complete: false, payload: payload)
        batch.save!
      end
    end

    def archived_chunk(state, index)
      scope = IngestionBatch.where(family_id: @control.family_id, provider_connection_id: @control.provider_connection_id,
        origin_kind: "migration", stream: self.class::STREAM, scope_key: scope_key, idempotency_key: batch_key(state, index))
      id, stored_bytes = scope.pick(:id, Arel.sql("octet_length(payload)"))
      unless id && stored_bytes.to_i <= state.fetch("chunk_bytes") * 3 + 64 * 1024
        raise Conflict, "Provider logo chunk is missing or exceeds its stored byte bound"
      end
      batch = scope.where("octet_length(payload) <= ?", state.fetch("chunk_bytes") * 3 + 64 * 1024).find(id)
      payload = batch.payload
      unless batch.sequence == index && batch.sync_id.nil? && batch.external_account_id.nil? && batch.mode == "unknown" && !batch.complete? &&
          payload.except("data") == { "format" => self.class::FORMAT, "source_digest" => state.fetch("source_digest"), "index" => index,
            "chunks" => state.fetch("chunks"), "chunk_bytes" => state.fetch("chunk_bytes") }
        raise Conflict, "Provider logo chunk provenance differs"
      end
      bytes = Base64.strict_decode64(payload.fetch("data"))
      total = validate_state!(state).fetch("blob").fetch("byte_size")
      expected = [ state.fetch("chunk_bytes"), total - index * state.fetch("chunk_bytes") ].min
      raise Conflict, "Provider logo archive chunk size differs" unless bytes.bytesize == expected
      bytes.b
    end

    def verify_archive!(state, lock: false)
      manifest = validate_state!(state)
      scope = IngestionBatch.where(provider_connection_id: @control.provider_connection_id, stream: self.class::STREAM).order(:sequence)
      scope = scope.lock("FOR SHARE NOWAIT") if lock
      inventory = scope.limit(state.fetch("chunks") + 1).pluck(:sequence, :idempotency_key)
      unless inventory == state.fetch("chunks").times.map { |index| [ index, batch_key(state, index) ] }
        raise Conflict, "Provider auxiliary archive inventory changed"
      end
      sha256, md5 = Digest::SHA256.new, Digest::MD5.new
      state.fetch("chunks").times do |index|
        bytes = archived_chunk(state, index)
        sha256.update(bytes)
        md5.update(bytes)
      end
      if manifest["blob"] && Base64.strict_encode64(md5.digest) != manifest.fetch("blob").fetch("checksum")
        raise Conflict, "Provider logo archive does not match its original storage checksum"
      end
      sha256.hexdigest
    end

    def target_attachments
      ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: @control.provider_connection_id, name: "logo").order(:id)
    end

    def validate_target!(state)
      manifest = validate_state!(state)
      rows = target_attachments.lock.limit(2).to_a
      unless rows.size <= 1 && rows.first&.blob_id == manifest["blob"]&.fetch("id") &&
          (state["target_attachment_id"].nil? || rows.first&.id == state["target_attachment_id"]) &&
          (!state.key?("retained_copy_context") || Provider::AccountData::MigrationValue.encode(rows.first&.attributes&.slice(*ATTACHMENT_COLUMNS)) == state["retained_target"])
        raise Conflict, "Disabled connection has a different logo; auxiliary copy never replaces it"
      end
      rows.first
    end

    def finalize!(state)
      sha256 = verify_archive!(state)
      manifest = validate_state!(state)
      rows = target_attachments.lock.limit(2).to_a
      raise Conflict, "Disabled connection has a different logo" if rows.size > 1 || (rows.first && rows.first.blob_id != manifest["blob"]&.fetch("id"))
      attachment = rows.first
      if manifest["attachment"] && !attachment
        # Bypass attachment callbacks: no analysis jobs, blob upload/copy or
        # purge may mutate source blob metadata while preserving this evidence.
        id = SecureRandom.uuid
        ActiveStorage::Attachment.insert_all!([ { id: id, name: "logo", record_type: "ProviderConnection", record_id: @connection.id,
          blob_id: manifest.fetch("blob").fetch("id"), created_at: manifest.fetch("attachment").fetch("created_at") } ])
        attachment = ActiveStorage::Attachment.find(id)
      end
      finished = state.merge("phase" => "complete", "content_sha256" => sha256,
        "target_attachment_id" => attachment&.id, "verified_at" => Time.current.iso8601,
        "source_quiesced_across_calls" => false, "requires_final_reverification" => true)
      finished["retained_target"] = Provider::AccountData::MigrationValue.encode(attachment&.attributes&.slice(*ATTACHMENT_COLUMNS)) if state.key?("retained_copy_context")
      @checkpoint.update!(state: finished)
    end

    def authorize_family!(family)
      unless family.is_a?(Family) && family.persisted? && family.id == @control.family_id
        raise Conflict, "Retained Provider auxiliary copy requires its authorized family"
      end
    end

    def retained_context(state)
      { "format" => self.class::RETAINED_FORMAT, "copy" => state.fetch("retained_copy_context"), "checkpoint_id" => @checkpoint.id,
        "source_digest" => state.fetch("source_digest"), "chunk_bytes" => state.fetch("chunk_bytes"), "chunks" => state.fetch("chunks"),
        "requires_cutover_reverification" => true }
    end

    def verification_context(state, limit:)
      retained_context(state).merge("content_sha256" => state.fetch("content_sha256"),
        "target_attachment" => state.fetch("retained_target"), "limit" => limit)
    end

    def validate_retained_snapshot!(state)
      validate_checkpoint!
      unless @checkpoint.state == state && state.fetch("retained_copy_context") == @current_copy_context
        raise Conflict, "Provider auxiliary receipt changed during verification"
      end
      validate_source!(state)
      validate_target!(state)
    end

    def financial_identity_progress?
      @connection.provider_sync_checkpoints.where(stream: "legacy_financial_identities").exists? ||
        @connection.ingestion_batches.where(stream: "legacy_financial_identities").exists? ||
        EntrySource.where(bootstrap_external_account_id: @connection.external_accounts.select(:id)).exists?
    end

    def immutable(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end

    def fingerprint(value)
      key = Rails.application.key_generator.generate_key(self.class::KEY_SALT, 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, Provider::AccountData::MigrationValue.dump(value))
    end

    def capture_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Provider auxiliary copy did not complete",
        source: self.class.name, provider_key: @manifest.provider_key, family: @control.family,
        metadata: { migration_control_id: @control.id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
