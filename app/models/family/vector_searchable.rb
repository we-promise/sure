module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    has_many :family_documents, dependent: :destroy
    # The store and its files go with the family: on OpenAI they would otherwise stay in the
    # Files API (spike, 2e).
    before_destroy :delete_vector_store
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

  # `user:` filters the hits down to the documents that user may read. The store
  # is a single family-wide index with no account dimension of its own, so the
  # filter has to happen here, on the way out. Optional only so existing callers
  # keep compiling; pass it whenever a specific person is asking.
  def search_documents(query, max_results: 10, user: nil)
    return [] unless vector_store_id.present?

    adapter = vector_store_adapter
    return [] unless adapter

    response = adapter.search(
      store_id: vector_store_id,
      query: query,
      max_results: max_results,
      family: self,
      user: user
    )

    return [] unless response.success?

    user ? readable_documents(response.data, user) : response.data
  end

  def readable_documents(results, user)
    file_ids = results.filter_map { |result| result[:file_id] }.uniq
    return results if file_ids.empty?

    # Anything the index returns that we have no row for stays visible: this
    # filter exists to stop a known leak, not to become a second, silent access
    # rule. What it withholds is decided in one place, FamilyDocument#readable_by,
    # which covers both a document naming an account the user cannot reach and an
    # account statement not yet matched to one (those follow
    # AccountStatement#viewable_by? and need a statement manager).
    withheld = family_documents.where(provider_file_id: file_ids)
                               .where.not(id: family_documents.readable_by(user).select(:id))
                               .pluck(:provider_file_id)
                               .to_set

    # A hit we have no row for stays visible by design, but it also means the
    # provider holds a file this app has lost track of and can no longer make
    # an access decision about. Recorded so support sees it, rather than
    # discovered the day it matters.
    untracked = file_ids - family_documents.where(provider_file_id: file_ids).pluck(:provider_file_id)
    if untracked.any?
      DebugLogEntry.capture(
        category: "documents",
        level: "warn",
        message: "Vector store returned #{untracked.size} file(s) with no family_documents row",
        source: "Family#readable_documents",
        family: self,
        metadata: { provider_file_ids: untracked.first(20) }
      )
    end

    return results if withheld.empty?

    results.reject { |result| withheld.include?(result[:file_id]) }
  end

  def upload_document(file_content:, filename:, metadata: {})
    adapter = vector_store_adapter
    return nil unless adapter

    store_id = ensure_vector_store!
    return nil unless store_id

    response = adapter.upload_file(
      store_id: store_id,
      file_content: file_content,
      filename: filename,
      family: self
    )

    return nil unless response.success?

    metadata = metadata || {}

    # An OpenAI store indexes in the background: the document is `processing` until
    # VectorStore::IndexStatusJob records the outcome, not `ready` before it can be found.
    family_documents.create!(
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      provider_file_id: response.data[:file_id],
      status: response.data[:status] || "ready",
      # Promoted out of metadata into a real column: a jsonb key cannot be
      # joined or indexed, and this one decides who may read the document.
      account_id: accounts.where(id: metadata["account_id"]).pick(:id),
      metadata: metadata
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

  def delete_vector_store
    return if vector_store_id.blank?

    adapter = vector_store_adapter
    response = adapter&.delete_store(store_id: vector_store_id)
    Rails.logger.warn("[Family] couldn't delete vector store for family #{id}") if response && !response.success?
  rescue StandardError => error
    Rails.logger.warn("[Family] couldn't delete vector store for family #{id}: #{error.class}")
  end

  private

    def vector_store_adapter
      VectorStore.adapter
    end
end
