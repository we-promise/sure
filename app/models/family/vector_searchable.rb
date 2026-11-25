module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    # Remember which backend created the store, and the files it never attached, before the
    # dependent destroy removes the documents that recorded them; the store and those files are
    # deleted only after the family deletion commits.
    before_destroy :remember_vector_store_cleanup
    has_many :family_documents, dependent: :destroy
    after_destroy_commit :delete_vector_store
  end

  # Ask for more candidates than we will show: a withheld hit must not use up the caller's limit.
  SEARCH_CANDIDATE_FACTOR = 3
  SEARCH_CANDIDATE_LIMIT = 50

  def ensure_vector_store!
    return vector_store_id if vector_store_id.present?

    adapter = vector_store_adapter
    return nil unless adapter

    response = adapter.create_store(name: "Family #{id} Documents")
    return nil unless response.success?

    if update(vector_store_id: response.data[:id], vector_store_endpoint: adapter.try(:endpoint_url))
      @vector_store_backend = VectorStore.backend_name(adapter)
      vector_store_id
    else
      adapter.delete_store(store_id: response.data[:id]) rescue nil
      nil
    end
  end

  # Ask wider than the caller's limit, then widen again while withheld hits hide readable ones.
  # A single wide request can still be exhausted by restricted rows, so the retry is bounded by
  # SEARCH_CANDIDATE_LIMIT rather than by the first candidate count. Returns the hits and the last
  # adapter response, so a caller that needs the provider error can report it.
  def search_document_hits(query, max_results:, user: nil)
    return [ [], nil ] unless vector_store_id.present?

    adapter = vector_store_adapter
    return [ [], nil ] unless adapter

    limit = [ SEARCH_CANDIDATE_FACTOR * max_results, SEARCH_CANDIDATE_LIMIT ].min
    loop do
      response = adapter.search(store_id: vector_store_id, query:, max_results: limit, family: self, user:)
      return [ [], response ] unless response.success?

      hits = user ? readable_documents(response.data, user, max_results:) : tracked_documents(response.data, max_results:)
      enough = hits.size >= max_results || response.data.size < limit || limit >= SEARCH_CANDIDATE_LIMIT
      return [ hits.first(max_results), response ] if enough

      limit = [ limit * 2, SEARCH_CANDIDATE_LIMIT ].min
    end
  end

  # `user:` filters the hits down to the documents that user may read; pass it whenever a person
  # is asking. The store is family-wide, so the filter is applied here, on the way out.
  def search_documents(query, max_results: 10, user: nil) = search_document_hits(query, max_results:, user:).first

  def readable_documents(results, user, max_results: nil)
    file_ids = results.filter_map { |result| result[:file_id] }.uniq
    return results if file_ids.empty?

    # An allowlist from one query: a hit is shown only with a row that is readable right now.
    # Untracked and restricted rows are both absent, so neither can slip through a second look.
    readable = family_documents.readable_by(user).where(provider_file_id: file_ids)
                               .pluck(:provider_file_id).to_set
    allowed = results.select { |result| result[:file_id].nil? || readable.include?(result[:file_id]) }
    max_results ? allowed.first(max_results) : allowed
  end

  # Without a user (MCP, the tool's own call): every hit Sure has a row for.
  def tracked_documents(results, max_results: nil)
    file_ids = results.filter_map { |result| result[:file_id] }.uniq
    return results if file_ids.empty?

    tracked = family_documents.where(provider_file_id: file_ids).pluck(:provider_file_id).to_set
    allowed = results.select { |result| result[:file_id].nil? || tracked.include?(result[:file_id]) }
    max_results ? allowed.first(max_results) : allowed
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

    metadata = (metadata || {}).merge("vector_store" => VectorStore.backend_name(adapter))

    # A failed compensating deletion leaves an uploaded file with no store attachment. Keep its
    # id in an error row so a later remove_file, or deleting the family, can still delete it. The
    # upload still failed: the row is not a search copy, so a later upload can try again.
    unless response.success?
      error = response.error
      return nil unless error.is_a?(VectorStore::UploadCleanupError)

      create_document_row!(adapter, store_id, error.file_id,
        filename: filename,
        content_type: Marcel::MimeType.for(name: filename),
        file_size: file_content.bytesize,
        provider_file_id: error.file_id,
        status: "error",
        account_id: accounts.where(id: metadata["account_id"]).pick(:id),
        metadata: metadata.merge("upload_error" => "attachment and cleanup failed",
                                 "cleanup_error" => error.cleanup_error.class.name)
      )
      return nil
    end

    # An OpenAI store indexes in the background: the document is `processing` until
    # VectorStore::IndexStatusJob records the outcome, not `ready` before it can be found.
    create_document_row!(adapter, store_id, response.data[:file_id],
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      provider_file_id: response.data[:file_id],
      status: response.data[:status] || "ready",
      account_id: accounts.where(id: metadata["account_id"]).pick(:id),
      metadata: metadata
    )
  end

  # Only a persistence failure removes the uploaded file: the poll enqueue happens after commit
  # and handles its own failures, so a committed row never loses the file it points at.
  def create_document_row!(adapter, store_id, file_id, **attributes)
    family_documents.create!(**attributes)
  rescue StandardError
    begin
      removed = adapter.remove_file(store_id:, file_id:).success?
    rescue StandardError => cleanup_error
      removed = false
    end
    Rails.logger.warn("[Family] couldn't remove unrecorded file #{file_id}: #{cleanup_error&.class || 'unsuccessful response'}") unless removed
    raise
  end

  def remove_document(family_document)
    adapter = document_adapter(family_document)
    return false unless adapter && vector_store_id.present? && family_document.provider_file_id.present?

    response = adapter.remove_file(
      store_id: vector_store_id,
      file_id: family_document.provider_file_id
    )

    return false unless response.success?

    family_document.destroy
    true
  end

  # The backend that accepted the document, which can differ from the configured one.
  def document_adapter(document) = store_adapter(document.metadata.to_h["vector_store"].presence || vector_store_backend)

  def delete_vector_store
    return if vector_store_id.blank?

    adapter = VectorStore.adapter_for(@vector_store_backend, endpoint_url: vector_store_endpoint)
    unless adapter
      Rails.logger.warn("[Family] no #{@vector_store_backend || 'configured'} vector store adapter to delete store #{vector_store_id} for family #{id}")
      return
    end

    # The store lists only attached files, so files whose attachment failed are deleted by id.
    Array(@unattached_file_ids).each do |file_id|
      removed = adapter.remove_file(store_id: vector_store_id, file_id:).success?
      Rails.logger.warn("[Family] couldn't delete unattached file #{file_id} for family #{id}") unless removed
    rescue StandardError => error
      Rails.logger.warn("[Family] couldn't delete unattached file #{file_id} for family #{id}: #{error.class}")
    end

    response = adapter.delete_store(store_id: vector_store_id)
    Rails.logger.warn("[Family] couldn't delete vector store for family #{id}") unless response.success?
  rescue StandardError => error
    Rails.logger.warn("[Family] couldn't delete vector store for family #{id}: #{error.class}")
  end

  private

    def remember_vector_store_cleanup
      @vector_store_backend = vector_store_backend
      @unattached_file_ids = family_documents.unattached.pluck(:provider_file_id)
    end

    # The configured backend for a new store. An existing store stays on the backend, and the
    # server, that created it, whatever is configured now.
    def vector_store_adapter = vector_store_id.present? ? store_adapter(vector_store_backend) : VectorStore.adapter

    # The backend that created the store: OpenAI when its server is recorded, otherwise the one its
    # newest document recorded. nil (before either was recorded) means the configured backend.
    def vector_store_backend
      return "openai" if vector_store_endpoint.present?

      family_documents.where("metadata->>'vector_store' IS NOT NULL").order(created_at: :desc)
                      .pick(Arel.sql("metadata->>'vector_store'"))
    end

    # An OpenAI store from before its server was recorded is pinned on first use to the server that
    # reaches it, which after the upgrade is its creator.
    def store_adapter(backend)
      VectorStore.adapter_for(backend, endpoint_url: vector_store_endpoint).tap do |adapter|
        update_column(:vector_store_endpoint, adapter.endpoint_url) if adapter.is_a?(VectorStore::Openai) && vector_store_endpoint.blank?
      end
    end
end
