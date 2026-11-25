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
        purge_file(document)
        return
      end

      # An asynchronous store keeps the upload until its poll reaches a terminal status.
      purge_file(document) if terminal_status?(document)
    rescue StandardError => e
      record_failure(document, family, "#{e.class}: #{e.message}")
      purge_file(document)
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

    def purge_file(document)
      document.purge_file
    end

    def terminal_status?(document)
      document.status.in?(%w[ready unreadable error])
    end
end
