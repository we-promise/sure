# The pending row holds the upload across the job boundary: a job argument can't carry the bytes.
class IndexFamilyDocumentJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  def perform(document)
    family = document.family
    index_document(document, family)
    purge_file(document)
  end

  private
    def index_document(document, family)
      availability = Ai.availability(:embed, family:)
      unless availability.available?
        return record_failure(document, family, "embeddings are no longer available: #{availability.reason}")
      end

      indexed = Ai::CallContext.job("family_document:#{document.id}") do
        family.index_document(document, file_content: document.file.download)
      end
      record_failure(document, family, "vector store refused the upload") unless indexed
    rescue Ai::Error::Busy
      raise # ApplicationJob retries with the upload still attached.
    rescue StandardError => e
      record_failure(document, family, "#{e.class}: #{e.message}")
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

    # Cleanup is separate from indexing: a storage failure here must not turn a settled row into
    # an error, and the result the job already recorded stays as it is.
    def purge_file(document)
      document.purge_file_if_settled
    rescue StandardError => e
      Rails.logger.warn("[IndexFamilyDocumentJob] couldn't purge the file for document #{document.id}: #{e.class}")
      DebugLogEntry.capture(
        category: "documents",
        level: "warn",
        message: "Couldn't purge the uploaded file for document: #{e.class}",
        source: "IndexFamilyDocumentJob",
        family: document.family,
        metadata: { family_document_id: document.id }
      )
    end
end
