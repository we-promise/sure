class FinancekitBatch < ApplicationRecord
  belongs_to :financekit_item
  belongs_to :sync, optional: true

  def self.accept!(item, envelope)
    Financekit.require!(envelope.is_a?(String) && envelope.bytesize <= Financekit::MAX_BYTES, "payload_too_large", 413)
    item.with_lock do
      item.require_writer!
      claims = Financekit::Crypto.verify(envelope, item)
      Financekit::Payload.uuid!(claims["batch_id"])
      Financekit.require!(claims["sequence"].is_a?(Integer) && claims["sequence"].between?(1, 9_007_199_254_740_991))
      Financekit.require!(claims["previous_digest"].nil? || /\A[0-9a-f]{64}\z/.match?(claims["previous_digest"].to_s))
      Financekit.require!((claims["sequence"] == 1) == claims["previous_digest"].nil?, "invalid_predecessor")
      existing = item.financekit_batches.find_by(generation: item.generation, batch_id: claims["batch_id"])
      if existing
        Financekit.require!(existing.digest == claims["digest"] && existing.sequence == claims["sequence"] && existing.previous_digest == claims["previous_digest"], "batch_conflict", 409)
        item.update!(last_device_contact_at: Time.current)
        return existing
      end
      Financekit.require!(claims["sequence"] >= item.next_sequence &&
        !item.financekit_batches.exists?(generation: item.generation, sequence: claims["sequence"]), "sequence_conflict", 409)
      Financekit.require!(claims["sequence"] < item.next_sequence + Financekit::MAX_QUEUED &&
        item.financekit_batches.where(status: %w[accepted processing]).count < Financekit::MAX_QUEUED, "inbox_full", 429)
      Financekit.require!(item.financekit_batches.where("created_at > ?", 1.hour.ago).count < 120, "rate_limited", 429)
      payload = Financekit::Payload.validate!(Financekit::Crypto.decrypt(claims["ciphertext"]), item)
      batch = item.financekit_batches.create!(batch_id: claims["batch_id"], generation: item.generation,
        sequence: claims["sequence"], digest: claims["digest"], previous_digest: claims["previous_digest"],
        captured_at: payload["captured_at"], envelope: envelope)
      item.update!(last_device_contact_at: Time.current, last_accepted_at: batch.created_at)
      batch
    end
    # There is intentionally no correctness dependency on an enqueue here:
    # FinancekitInboxJob discovers committed rows on every server-side sweep.
  end
end
