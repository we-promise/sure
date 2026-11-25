# Indexes a non-PDF document uploaded from the browser, on `embed`'s lane. The pending row holds
# the upload until this job sends it to the store; the file is purged only after a terminal status.
class IndexFamilyDocumentJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  discard_on ActiveJob::DeserializationError

  def perform(document)
    return unless document.is_a?(FamilyDocument)

    family = document.family
    return unless Ai.available?(:embed, family:)

    index_or_record_failure(document, family)
  end

  private
    def index_or_record_failure(document, family)
      indexed = family.index_document(document, file_content: document.file.download)
      unless indexed
        record_failure(document, family, "vector store refused the upload")
        document.purge_file
        return
      end

      # An asynchronous store keeps the upload until its poll reaches a terminal status.
      document.purge_file if terminal_status?(document)
    rescue Ai::Error::Busy
      raise # ApplicationJob retries a busy local host with the upload left attached.
    rescue StandardError => e
      record_failure(document, family, "#{e.class}: #{e.message}")
      document.purge_file
    end

    def record_failure(document, family, reason)
      document.mark_error!(reason)
      DebugLogEntry.capture(
        category: "documents",
        level: "warn",
        message: "Vector store indexing failed for document: #{reason}",
        source: "IndexFamilyDocumentJob",
        family: family,
        metadata: { family_document_id: document.id }
      )
    end

    def terminal_status?(document)
      document.status.in?(%w[ready unreadable error])
    end
end
