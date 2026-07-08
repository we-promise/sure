class RemoveTransactionAttachmentJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveJob::DeserializationError

  # Removes a transaction attachment from the family's vector store after the
  # attachment has been deleted. The blob is already purged by the time this
  # runs, so we locate the indexed document by the blob id stored in metadata.
  #
  # @param family [Family]
  # @param blob_id [Integer, String] the purged attachment's blob id
  def perform(family, blob_id)
    return unless VectorStore.configured?

    family.family_documents
          .where("metadata ->> 'attachment_blob_id' = ?", blob_id.to_s)
          .find_each do |family_document|
      family.remove_document(family_document)
    end
  end
end
