# The pending row holds the upload across the job boundary: a job argument can't carry the bytes.
class IndexFamilyDocumentJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  def perform(document)
    family = document.family
    return unless Ai.available?(:embed, family:)

    indexed = family.index_document(document, file_content: document.file.download)
    if indexed
      document.purge_file_if_settled
    else
      record_failure(document, family, "vector store refused the upload")
      document.purge_file_if_settled
    end
  rescue StandardError => e
    raise if e.is_a?(Ai::Error::Busy) # ApplicationJob retries with the upload still attached.

    record_failure(document, family, "#{e.class}: #{e.message}")
    document.purge_file_if_settled
  end

  private
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
end
