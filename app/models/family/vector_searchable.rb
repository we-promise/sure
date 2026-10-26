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
      max_results: max_results
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

  # Stores one document for the family: the bytes on the row itself, a copy in
  # the vector store for search. The same bytes uploaded twice return the
  # document already on file rather than a second row and a second provider
  # file, the rule the Statement Vault applies to statements.
  #
  # kind defaults from the classifier type in metadata["type"]; the other
  # document attributes are optional and only set when the caller knows them.
  def upload_document(file_content:, filename:, metadata: {}, kind: nil, tax_year: nil, issuer_name: nil, document_date: nil, title: nil)
    metadata = (metadata || {}).stringify_keys
    content_sha256 = FamilyDocument.content_digest(file_content)

    existing = family_documents.find_by(content_sha256: content_sha256)
    return adopt_duplicate_document(existing, metadata) if existing

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

    content_type = Marcel::MimeType.for(name: filename)

    family_documents.create!(
      filename: filename,
      content_type: content_type,
      file_size: file_content.bytesize,
      content_sha256: content_sha256,
      provider_file_id: response.data[:file_id],
      status: "ready",
      kind: kind.presence || FamilyDocument.kind_for_import_type(metadata["type"]),
      tax_year: tax_year,
      issuer_name: issuer_name,
      document_date: document_date,
      title: title,
      # Promoted out of metadata into a real column: a jsonb key cannot be
      # joined or indexed, and this one decides who may read the document.
      account_id: accounts.where(id: metadata["account_id"]).pick(:id),
      metadata: metadata,
      # The bytes are the record. Without them a document cannot be downloaded,
      # re-indexed on another provider, or included in a family data export.
      file: { io: StringIO.new(file_content), filename: filename, content_type: content_type }
    )
  rescue ActiveRecord::RecordNotUnique
    # Two uploads of the same bytes raced past the lookup above; the unique
    # index let exactly one row in, and that row is the answer for both.
    existing = family_documents.find_by(content_sha256: content_sha256)
    raise unless existing

    # The losing upload already reached the provider and nothing will ever
    # point at that copy, so it goes too.
    if adapter && store_id && response&.success? && response.data[:file_id] != existing.provider_file_id
      adapter.remove_file(store_id: store_id, file_id: response.data[:file_id]) rescue nil
    end

    adopt_duplicate_document(existing, metadata)
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

    # A duplicate upload still carries what its caller knows: the Statement
    # Vault bridge, for one, sends the statement id it uses as an idempotency
    # key, and an /imports upload of the same bytes would otherwise leave that
    # statement looking unindexed forever. Keys already on the document win,
    # and an account is only ever added, never replaced: replacing it could
    # move the document out of reach of someone who can read it today.
    def adopt_duplicate_document(document, metadata)
      merged = (document.metadata || {}).reverse_merge(metadata.except("type"))
      account_id = document.account_id || accounts.where(id: metadata["account_id"]).pick(:id)

      if merged != document.metadata || account_id != document.account_id
        document.update!(metadata: merged, account_id: account_id)
      end

      document
    end

    def vector_store_adapter
      VectorStore.adapter
    end
end
