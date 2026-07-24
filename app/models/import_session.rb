require "digest"

class ImportSession < ApplicationRecord
  ConflictError = Class.new(StandardError)
  EnqueueError = Class.new(StandardError)

  IMPORT_TYPES = %w[SureImport].freeze
  STATUSES = %w[pending importing complete failed].freeze

  belongs_to :family
  has_many :imports, -> { order(:sequence, :created_at) }, dependent: :destroy
  has_many :source_mappings,
           class_name: "ImportSourceMapping",
           dependent: :destroy

  enum :status, {
    pending: "pending",
    importing: "importing",
    complete: "complete",
    failed: "failed"
  }, validate: true, default: "pending"

  validates :import_type, inclusion: { in: IMPORT_TYPES }
  validates :client_session_id, uniqueness: { scope: :family_id }, allow_blank: true
  validates :client_session_id, length: { maximum: 255 }, allow_blank: true
  normalizes :client_session_id, with: ->(value) { value.strip.presence }
  validates :expected_chunks,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true
  validate :payloads_are_json_objects

  # See Import::STUCK_AFTER — same dead-worker failure mode, same sweep.
  # A session wedged in importing is otherwise unrecoverable: publish_later
  # refuses to re-publish while importing. Before failing it, chunks whose
  # import! committed but never got their complete-status write are
  # reconciled — otherwise the re-publish would run those chunks again
  # (process_chunk! only skips complete ones) and double-import their rows.
  # Failing the session then re-enables re-publish, which resumes safely at
  # the first genuinely incomplete chunk.
  def self.clean
    where(status: :importing)
      .where("updated_at < ?", Import::STUCK_AFTER.ago)
      .includes(:family)
      .find_each do |session|
        # Read before the lock — see Import.reap_stuck!.
        family = session.family

        # Row-lock + staleness re-check before mutating, as Sync#perform
        # does since #2680 — the owning job may have finished in between.
        session.with_lock do
          next unless session.importing? && session.updated_at < Import::STUCK_AFTER.ago

          session.reconcile_committed_chunks!
          session.update!(
            status: :failed,
            error_details: {
              "code" => "import_interrupted",
              "message" => Import.interrupted_error_message
            }
          )

          DebugLogEntry.capture(
            category: "background_jobs",
            level: "warn",
            message: "Reaped ImportSession stuck in importing for over #{Import::STUCK_AFTER.inspect}",
            source: name,
            family: family,
            metadata: { record_type: name, record_id: session.id, previous_status: "importing", new_status: "failed" }
          )
        end
      rescue => e
        # One bad record must not abort the sweep for the rest.
        Rails.logger.error("ImportSession.clean failed for #{session.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: name, record_id: session.id) } if defined?(Sentry)
      end
  end

  # Chunks caught by a worker kill between import!'s commit and the
  # complete-status write have their rows attached but still read importing.
  # Mark them complete so a re-publish skips them instead of importing the
  # same rows twice (SureImport's split path would duplicate child entries).
  # The chunk's summary was lost with the job; aggregate_chunk_summaries
  # tolerates the empty hash.
  def reconcile_committed_chunks!
    # Plain each: the association carries a default order (find_each would
    # log a scoped-order warning) and sessions cap out at a handful of chunks.
    imports.where(status: :importing).each do |chunk|
      next unless chunk.data_committed?

      chunk.update!(status: :complete, error: nil, error_details: {})

      DebugLogEntry.capture(
        category: "background_jobs",
        level: "warn",
        message: "Reconciled ImportSession chunk whose data committed before the worker died",
        source: self.class.name,
        family: family,
        metadata: { record_type: chunk.type, record_id: chunk.id, import_session_id: id }
      )
    end
  end

  def self.create_or_find_for!(family:, import_type:, client_session_id:, expected_chunks:)
    import_type = import_type.presence || "SureImport"
    expected_chunks = normalize_positive_integer(expected_chunks)
    unless IMPORT_TYPES.include?(import_type)
      session = new(import_type: import_type)
      session.errors.add(:import_type, "must be SureImport")
      raise ActiveRecord::RecordInvalid.new(session)
    end

    if client_session_id.present?
      session = family.import_sessions.find_or_initialize_by(client_session_id: client_session_id)
      if session.persisted? &&
         expected_chunks.present? &&
         session.expected_chunks.present? &&
         session.expected_chunks != expected_chunks
        raise ConflictError, "client_session_id already exists with a different expected_chunks value"
      end
    else
      session = family.import_sessions.build
    end

    session.import_type = import_type
    session.expected_chunks ||= expected_chunks
    session.save!
    session
  rescue ActiveRecord::RecordNotUnique
    raise unless client_session_id.present?

    existing = family.import_sessions.find_by(client_session_id: client_session_id)
    raise unless existing

    if expected_chunks.present? &&
       existing.expected_chunks.present? &&
       existing.expected_chunks != expected_chunks
      raise ConflictError, "client_session_id already exists with a different expected_chunks value"
    end
    if expected_chunks.present? && existing.expected_chunks.nil?
      existing.update!(expected_chunks: expected_chunks)
    end

    existing
  end

  def self.normalize_positive_integer(value)
    return if value.blank?

    Integer(value, exception: false) || 0
  end
  private_class_method :normalize_positive_integer

  def attach_chunk!(sequence:, content:, filename:, content_type:, client_chunk_id: nil)
    sequence = self.class.send(:normalize_positive_integer, sequence)
    raise ConflictError, "sequence must be a positive integer" unless sequence.positive?
    raise ConflictError, "sequence exceeds expected_chunks" if expected_chunks.present? && sequence > expected_chunks

    checksum = Digest::SHA256.hexdigest(content)
    normalized_client_chunk_id = client_chunk_id.presence
    chunk_needs_finalization = false

    chunk = with_lock do
      raise ConflictError, "cannot add chunks after publishing starts" unless pending? || failed?

      existing = existing_chunk_for!(
        sequence: sequence,
        client_chunk_id: normalized_client_chunk_id,
        checksum: checksum
      )

      if existing
        chunk_needs_finalization = prepare_existing_chunk_for_retry!(
          existing,
          checksum: checksum,
          content: content,
          filename: filename,
          content_type: content_type
        )
        existing
      else
        chunk_needs_finalization = true
        chunk = create_chunk!(
          sequence: sequence,
          client_chunk_id: normalized_client_chunk_id,
          checksum: checksum,
          content: content,
          filename: filename,
          content_type: content_type
        )
      end
    end

    finalize_chunk_for_retry!(chunk, checksum) if chunk_needs_finalization
    chunk
  rescue ActiveRecord::RecordNotUnique
    imports.reset
    existing = existing_chunk_for!(
      sequence: sequence,
      client_chunk_id: normalized_client_chunk_id,
      checksum: checksum
    )
    return prepare_and_finalize_existing_chunk!(
      existing,
      checksum: checksum,
      content: content,
      filename: filename,
      content_type: content_type
    ) if existing

    raise ConflictError, "chunk already exists with different content"
  end

  def create_chunk!(sequence:, client_chunk_id:, checksum:, content:, filename:, content_type:)
    imports.create!(
      family: family,
      type: "SureImport",
      sequence: sequence,
      client_chunk_id: client_chunk_id,
      checksum: checksum
    ).tap do |import|
      import.ndjson_file.attach(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type
      )
    end
  end
  private :create_chunk!

  def publish_later
    previous_status = nil
    should_enqueue = false

    sync_chunk_row_counts!

    with_lock do
      return if complete? || importing?

      validate_publishable_chunks!

      previous_status = status
      update!(status: :importing, error_details: {})
      should_enqueue = true
    end

    return unless should_enqueue

    begin
      ImportSessionJob.perform_later(self)
    rescue => error
      with_lock do
        reload
        if importing?
          update!(status: previous_status, error_details: enqueue_error_details)
        end
      end
      Rails.logger.error("ImportSession enqueue failed import_session_id=#{id} exception=#{error.class}")
      raise EnqueueError, "Import session could not be queued."
    end
  end

  def publish
    return unless prepare_for_publish!

    Rails.logger.info("ImportSession publish started import_session_id=#{id}")

    imports.ordered_by_sequence.each do |import|
      process_chunk!(import)
    end

    update!(status: :complete, summary: aggregate_chunk_summaries, error_details: {})
    enqueue_family_sync
    Rails.logger.info("ImportSession publish completed import_session_id=#{id}")
  rescue => error
    update!(
      status: :failed,
      error_details: error_details_for(error),
      summary: aggregate_chunk_summaries
    )
    Rails.logger.error("ImportSession publish failed import_session_id=#{id} exception=#{error.class}")
  end

  def aggregate_chunk_summaries
    imports.reload.each_with_object({}) do |import, totals|
      merge_summary!(totals, import.summary || {})
    end
  end

  private
    def prepare_for_publish!
      sync_chunk_row_counts!

      with_lock do
        return false if complete?

        validate_publishable_chunks!

        update!(status: :importing, error_details: {}) unless importing?
        true
      end
    end

    def enqueue_family_sync
      family.sync_later
    rescue => error
      update!(error_details: sync_enqueue_error_details)
      Rails.logger.error(
        "ImportSession family sync enqueue failed import_session_id=#{id} exception=#{error.class}"
      )
    end

    def existing_chunk_for!(sequence:, client_chunk_id:, checksum:)
      sequence_match = imports.find_by(sequence: sequence)
      client_chunk_match = imports.find_by(client_chunk_id: client_chunk_id) if client_chunk_id.present?

      if sequence_match && client_chunk_match && sequence_match.id != client_chunk_match.id
        raise ConflictError, "sequence and client_chunk_id refer to different chunks"
      end

      existing = sequence_match || client_chunk_match
      return unless existing

      if existing.sequence != sequence
        raise ConflictError, "client_chunk_id already exists with a different sequence"
      end

      if client_chunk_id.present? && existing.client_chunk_id.present? && existing.client_chunk_id != client_chunk_id
        raise ConflictError, "sequence already exists with a different client_chunk_id"
      end

      raise ConflictError, "chunk already exists with different content" unless existing.checksum == checksum

      existing
    end

    def prepare_and_finalize_existing_chunk!(chunk, checksum:, content:, filename:, content_type:)
      needs_finalization = with_lock do
        prepare_existing_chunk_for_retry!(
          chunk.reload,
          checksum: checksum,
          content: content,
          filename: filename,
          content_type: content_type
        )
      end

      finalize_chunk_for_retry!(chunk, checksum) if needs_finalization
      chunk
    end

    def prepare_existing_chunk_for_retry!(chunk, checksum:, content:, filename:, content_type:)
      return false if chunk_ready_for_retry?(chunk, checksum)
      return true if chunk.ndjson_file.attached? && chunk_content_checksum(chunk) == checksum

      chunk.ndjson_file.attach(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type
      )
      true
    end

    def finalize_chunk_for_retry!(chunk, checksum)
      chunk.sync_ndjson_rows_count!
      chunk.reload
      return chunk if chunk_ready_for_retry?(chunk, checksum)

      raise ConflictError, "chunk already exists but is incomplete"
    rescue ActiveStorage::FileNotFoundError
      raise ConflictError, "chunk already exists but is incomplete"
    end

    def chunk_ready_for_retry?(chunk, checksum)
      chunk.ndjson_file.attached? &&
        chunk.rows_count.to_i.positive? &&
        chunk_content_checksum(chunk) == checksum
    end

    def chunk_content_checksum(chunk)
      Digest::SHA256.hexdigest(chunk.ndjson_file.download)
    rescue ActiveStorage::FileNotFoundError
      nil
    end

    def process_chunk!(import)
      return if import.complete?

      import.update!(status: :importing, error: nil, error_details: {})
      result = import.import!(import_session: self)
      import.update!(status: :complete, summary: result.fetch(:summary, {}), error_details: {})
    rescue => error
      import.update!(
        status: :failed,
        error: public_error_message_for(error),
        error_details: error_details_for(error),
        summary: failed_summary_for(error)
      )
      raise
    end

    def row_count_exceeded?
      imports.sum(:rows_count) > SureImport.max_row_count
    end

    def validate_publishable_chunks!
      raise ConflictError, "import session has no chunks" unless imports.exists?
      raise Import::MaxRowCountExceededError if row_count_exceeded?
      validate_expected_chunk_sequences!
    end

    def sync_chunk_row_counts!
      raise ConflictError, "import session has no chunks" unless imports.exists?
      imports.reload.each(&:sync_ndjson_rows_count!)
    rescue ActiveStorage::FileNotFoundError
      raise ConflictError, "import session chunks are incomplete"
    end

    def validate_expected_chunk_sequences!
      return if expected_chunks.blank?

      expected_sequences = (1..expected_chunks).to_a
      actual_sequences = imports.pluck(:sequence).sort
      return if actual_sequences == expected_sequences

      missing_sequences = expected_sequences - actual_sequences
      unexpected_sequences = actual_sequences - expected_sequences
      details = []
      details << "missing sequences: #{missing_sequences.join(', ')}" if missing_sequences.any?
      details << "unexpected sequences: #{unexpected_sequences.join(', ')}" if unexpected_sequences.any?

      raise ConflictError, "import session chunks do not match expected sequences (#{details.join('; ')})"
    end

    def error_details_for(error)
      details = {
        "code" => error.respond_to?(:code) ? error.code : "import_failed",
        "message" => public_error_message_for(error)
      }

      if error.respond_to?(:details)
        details.merge!(error.details.stringify_keys)
      end

      details
    end

    def public_error_message_for(error)
      return error.message if error.respond_to?(:code)

      "Import session failed."
    end

    def enqueue_error_details
      {
        "code" => "import_enqueue_failed",
        "message" => "Import session could not be queued."
      }
    end

    def sync_enqueue_error_details
      {
        "code" => "family_sync_enqueue_failed",
        "message" => "Family sync could not be queued after import completion."
      }
    end

    def merge_summary!(totals, summary)
      summary.each do |entity_type, counts|
        next unless counts.respond_to?(:each)

        totals[entity_type] ||= {}
        counts.each do |status, count|
          totals[entity_type][status] = totals[entity_type].fetch(status, 0) + count.to_i
        end
      end
    end

    def failed_summary_for(error)
      record_type = error_details_for(error)["record_type"]
      return {} if record_type.blank?

      {
        record_type.to_s.underscore.pluralize => {
          "created" => 0,
          "updated" => 0,
          "skipped" => 0,
          "failed" => 1
        }
      }
    end

    def payloads_are_json_objects
      errors.add(:summary, "must be an object") unless summary.is_a?(Hash)
      errors.add(:error_details, "must be an object") unless error_details.is_a?(Hash)
    end
end
