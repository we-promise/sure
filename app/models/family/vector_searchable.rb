module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    has_many :family_documents, dependent: :destroy
  end

  def ensure_vector_store!
    return vector_store_id if vector_store_id.present?

    adapter = vector_store_adapter
    return nil unless adapter

    response = adapter.create_store(name: "Family #{id} Documents")
    return nil unless response.success?

    if update(vector_store_id: response.data[:id])
      vector_store_id
    else
      adapter.delete_store(store_id: response.data[:id]) rescue nil
      nil
    end
  end

  def search_documents(query, max_results: 10)
    return [] unless vector_store_id.present?

    adapter = vector_store_adapter
    return [] unless adapter

    response = adapter.search(
      store_id: vector_store_id,
      query: query,
      max_results: max_results
    )

    response.success? ? response.data : []
  end

  def upload_document(file_content:, filename:, metadata: {})
    adapter = vector_store_adapter
    return nil unless adapter

    store_id = ensure_vector_store!
    return nil unless store_id

    response = adapter.upload_file(
      store_id: store_id,
      file_content: file_content,
      filename: filename
    )

    return nil unless response.success?

    family_documents.create!(
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      provider_file_id: response.data[:file_id],
      status: "ready",
      metadata: metadata || {}
    )
  end

  def remove_document(family_document)
    adapter = vector_store_adapter
    return false unless adapter && vector_store_id.present? && family_document.provider_file_id.present?

    response = adapter.remove_file(
      store_id: vector_store_id,
      file_id: family_document.provider_file_id
    )

    return false unless response.success?

    family_document.destroy
    true
  end

  private

    def vector_store_adapter
      VectorStore.adapter
    end
end
