# Waits for an asynchronous vector store (OpenAI's) to index a document, and records how it went:
# `ready` once it can be found, `unreadable` for an empty index (a scan, which file search can't
# read), `error` when indexing failed. Indexing takes ~6 s a statement; the job looks again every
# POLL_INTERVAL, MAX_POLLS times, on `embed`'s lane.
class VectorStore::IndexStatusJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  POLL_INTERVAL = 5.seconds
  MAX_POLLS = 120   # ten minutes

  discard_on ActiveJob::DeserializationError

  def perform(document, polls = 1)
    return unless document.status == "processing"

    family = document.family
    adapter = VectorStore.adapter
    return document.mark_error!("vector store no longer configured") if adapter.nil? || family.vector_store_id.blank?

    response = adapter.file_status(store_id: family.vector_store_id, file_id: document.provider_file_id)
    status = response.success? ? response.data[:status] : "processing"

    case status
    when "processing"
      return document.mark_error!("indexing didn't finish") if polls >= MAX_POLLS

      self.class.set(wait: POLL_INTERVAL).perform_later(document, polls + 1)
    when "error" then document.mark_error!(response.data[:error])
    else document.update!(status:)
    end
  end
end
