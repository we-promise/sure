module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    has_many :family_documents, dependent: :destroy
    has_many :document_stores, class_name: "Family::DocumentStore", dependent: :destroy
  end

  def document_store_context
    VectorStore.context(family: self)
  end

  def ensure_vector_store!
    document_store_context.ensure_store!
  end

  def search_documents(query, max_results: 10)
    context = document_store_context
    return [] unless context.adapter && context.store_id.present?

    response = context.adapter.search(store_id: context.store_id, query: query, max_results: max_results)
    response.success? ? response.data : []
  end

  def upload_document(file_content:, filename:, metadata: {})
    context = document_store_context
    store_id = context.ensure_store!
    return nil unless store_id

    response = context.adapter.upload_file(
      store_id: store_id,
      file_content: file_content,
      filename: filename
    )

    return nil unless response.success?

    family_documents.create!(
      family_document_store: context.family_document_store,
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      provider_file_id: response.data[:file_id],
      status: "ready",
      metadata: metadata || {}
    )
  end

  def remove_document(family_document)
    document = family_documents.find_by(id: family_document.id)
    return false unless document&.provider_file_id.present?

    context = document_store_context
    return false unless context.owns_document?(document)

    response = context.adapter.remove_file(store_id: context.store_id, file_id: document.provider_file_id)
    return false unless response.success?

    document.destroy!
    true
  end
end
