class Financekit::Diagnostics
  # Only operational identifiers and counts belong here. Never pass exception
  # messages, payloads, credentials, or financial fields into debug metadata.
  def self.capture(item:, source:, message:, level: "info", batch: nil, account_provider: nil, **details)
    metadata = {
      connection_id: item.id, publisher_id: item.publisher_id,
      generation: item.generation, stream_id: item.stream_id,
      connection_status: item.status, next_sequence: item.next_sequence
    }
    if batch
      metadata.merge!(batch_id: batch.batch_id, capture_id: batch.capture_id,
        sequence: batch.sequence, chunk_index: batch.chunk_index, chunk_count: batch.chunk_count,
        batch_status: batch.status, attempts: batch.attempts, retry_at: batch.retry_at&.iso8601)
    end

    DebugLogEntry.capture(category: "provider_sync", level: level, message: message,
      source: source, provider_key: "financekit", family: item.family, user: item.user,
      account_provider: account_provider, metadata: metadata.merge(details))
  end
end
