class IndexTransactionAttachmentJob < ApplicationJob
  queue_as :low_priority

  # If the transaction or blob was deleted before this job ran, there's nothing
  # to index — drop it quietly rather than retrying forever.
  discard_on ActiveJob::DeserializationError

  # Indexes a transaction's file attachment into the family's vector store so it
  # becomes available for semantic search (mirrors ProcessPdfJob's upload).
  #
  # @param transaction [Transaction]
  # @param blob [ActiveStorage::Blob] the attached file's blob
  def perform(transaction, blob)
    return unless VectorStore.configured?
    return unless supported_extension?(blob)

    family = transaction.entry.account.family

    # Idempotent: avoid re-uploading the same attachment (e.g. on retry).
    return if document_exists?(family, blob)

    family.upload_document(
      file_content: blob.download,
      filename: blob.filename.to_s,
      metadata: {
        "type" => "transaction_attachment",
        "transaction_id" => transaction.id,
        "attachment_blob_id" => blob.id.to_s
      }
    )
  end

  private

    def supported_extension?(blob)
      ext = File.extname(blob.filename.to_s).downcase
      VectorStore::Base::SUPPORTED_EXTENSIONS.include?(ext)
    end

    def document_exists?(family, blob)
      family.family_documents
            .where("metadata ->> 'attachment_blob_id' = ?", blob.id.to_s)
            .exists?
    end
end
