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
    return mark_error_if_processing(document, "vector store no longer configured") if family.vector_store_id.blank?

    # Another store can't speak for this one's file (pgvector would call any id ready).
    accepted_by = document.metadata.to_h["vector_store"]
    adapter = adapter_for(accepted_by)
    if adapter.nil?
      message = accepted_by.present? ? "the vector store changed from #{accepted_by} while it indexes" : "vector store no longer configured"
      return mark_error_if_processing(document, message)
    end

    response = adapter.file_status(store_id: family.vector_store_id, file_id: document.provider_file_id)
    status = response.success? ? response.data[:status] : "processing"

    case status
    when "processing"
      return mark_error_if_processing(document, "indexing didn't finish") if polls >= MAX_POLLS

      enqueue_next_poll(document, polls)
    when "error" then mark_error_if_processing(document, response.data[:error])
    else document.update!(status:)
    end
  end

  private
    # Poll the backend that accepted the file, not whichever one is configured now. Only OpenAI
    # indexes asynchronously, but a document predating the recorded backend still uses the
    # configured adapter.
    def adapter_for(backend)
      return VectorStore.adapter if backend.blank?
      return VectorStore::Openai.from_config if backend == "openai"
      return VectorStore::Pgvector.new if backend == "pgvector" && VectorStore::Pgvector.available?

      configured = VectorStore.adapter
      configured if configured && VectorStore.backend_name(configured) == backend
    end

    # Polls overlap: an old one must not turn a `ready` row back into `error`. `with_lock` reloads
    # the row under the lock, so the decision is made against its current state.
    def mark_error_if_processing(document, message)
      document.with_lock do
        document.mark_error!(message) if document.status == "processing"
      end
    end

    # A rejected requeue leaves the row processing; poll_index_later can recover it.
    def enqueue_next_poll(document, polls)
      self.class.set(wait: POLL_INTERVAL).perform_later(document, polls + 1)
    rescue StandardError => e
      Rails.logger.warn("[VectorStore::IndexStatusJob] couldn't requeue poll for document #{document.id}: #{e.class}")
    end
end
