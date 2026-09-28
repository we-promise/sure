class FinancekitBatch < ApplicationRecord
  belongs_to :financekit_item
  belongs_to :sync, optional: true

  def self.accept!(item, raw_payload, claimed_digest: nil, idempotency_key: nil)
    Financekit.require!(raw_payload.is_a?(String) && raw_payload.bytesize <= Financekit::MAX_BYTES,
      "payload_too_large", 413)
    digest = Digest::SHA256.hexdigest(raw_payload)
    Financekit.require!(claimed_digest.blank? || claimed_digest == digest, "payload_digest_mismatch", 409)
    data = JSON.parse(raw_payload)
    # validate_batch! proves the shape, but it runs behind the item lock and the
    # idempotency comparison below already indexes the body by key.
    Financekit.require!(data.is_a?(Hash))
    Financekit.require!(idempotency_key.blank? || idempotency_key.casecmp?(data["batch_id"].to_s),
      "idempotency_key_mismatch", 409)

    batch = nil
    item.with_lock do
      item.require_publisher!
      Financekit::Payload.validate_batch!(data, item)
      existing = item.financekit_batches.find_by(generation: item.generation, batch_id: data["batch_id"])
      if existing
        Financekit.require!(existing.payload_digest == digest && existing.sequence == data["sequence"] &&
          existing.predecessor_digest == data["predecessor_digest"] && existing.stream_id.casecmp?(data["stream_id"]),
          "batch_conflict", 409)
        item.update!(last_device_contact_at: Time.current)
        batch = existing
        next
      end

      Financekit.require!(data["sequence"] >= item.next_sequence &&
        !item.financekit_batches.exists?(generation: item.generation, stream_id: item.stream_id, sequence: data["sequence"]),
        "sequence_conflict", 409)
      capture = item.financekit_batches.where(generation: item.generation, capture_id: data["capture_id"]).order(:chunk_index)
      if capture.exists?
        first = capture.first
        Financekit.require!(first.chunk_count == data["chunk_count"] && first.capture_mode == data["capture_mode"] &&
          first.captured_at == Financekit::Payload.timestamp!(data["captured_at"]) &&
          data["chunk_index"] == capture.maximum(:chunk_index) + 1 &&
          data["sequence"] == capture.maximum(:sequence) + 1, "capture_conflict", 409)
      else
        Financekit.require!(data["chunk_index"] == 0, "capture_conflict", 409)
        incomplete = item.financekit_batches.where(generation: item.generation).where.not(status: %w[applied failed revoked])
          .group(:capture_id, :chunk_count).having("COUNT(*) < chunk_count").exists?
        Financekit.require!(!incomplete, "capture_incomplete", 409)
      end
      Financekit.require!(data["sequence"] < item.next_sequence + Financekit::MAX_QUEUED &&
        item.financekit_batches.where(status: %w[accepted processing]).count < Financekit::MAX_QUEUED,
        "inbox_full", 429)
      accepted_at = Time.current
      batch = item.financekit_batches.create!(batch_id: data["batch_id"], stream_id: data["stream_id"],
        capture_id: data["capture_id"], generation: data["generation"], sequence: data["sequence"],
        predecessor_digest: data["predecessor_digest"], payload_digest: digest,
        chunk_index: data["chunk_index"], chunk_count: data["chunk_count"], capture_mode: data["capture_mode"],
        snapshot_complete: data["snapshot_complete"], captured_at: Financekit::Payload.timestamp!(data["captured_at"]),
        accepted_at: accepted_at, payload: raw_payload)
      item.update!(last_device_contact_at: accepted_at, last_accepted_at: accepted_at)
    end
    FinancekitInboxJob.perform_later(item.id) if batch.previously_new_record?
    batch
  rescue JSON::ParserError
    raise Financekit::Error.new("invalid_json", 400)
  end

  def receipt
    {
      connection_id: financekit_item_id,
      publisher_id: financekit_item.publisher_id,
      generation: generation,
      stream_id: stream_id,
      batch_id: batch_id,
      sequence: sequence,
      payload_digest: payload_digest,
      status: status,
      accepted_at: accepted_at,
      applied_at: applied_at,
      error_code: error_code
    }
  end
end
