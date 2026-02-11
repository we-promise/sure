module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    has_many :family_documents, dependent: :destroy
  end

  def ensure_vector_store!
    return vector_store_id if vector_store_id.present?

    provider = vector_store_provider
    return nil unless provider

    response = provider.create_vector_store(name: "Family #{id} Documents")
    return nil unless response.success?

    update!(vector_store_id: response.data[:id])
    vector_store_id
  end

  def search_documents(query, max_results: 10)
    return [] unless vector_store_id.present?

    provider = vector_store_provider
    return [] unless provider

    response = provider.search_vector_store(
      vector_store_id: vector_store_id,
      query: query,
      max_results: max_results
    )

    response.success? ? response.data : []
  end

  def upload_document(file_content:, filename:)
    provider = vector_store_provider
    return nil unless provider

    store_id = ensure_vector_store!
    return nil unless store_id

    response = provider.upload_file_to_vector_store(
      vector_store_id: store_id,
      file_content: file_content,
      filename: filename
    )

    return nil unless response.success?

    doc = family_documents.create!(
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      provider_file_id: response.data[:file_id],
      status: "ready"
    )

    doc
  end

  def remove_document(family_document)
    provider = vector_store_provider
    return false unless provider && vector_store_id.present? && family_document.provider_file_id.present?

    provider.remove_file_from_vector_store(
      vector_store_id: vector_store_id,
      file_id: family_document.provider_file_id
    )

    family_document.destroy
    true
  end

  private

    def vector_store_provider
      provider = Provider::Registry.get_provider(:openai)
      return nil unless provider&.supports_vector_store?
      provider
    end
end
