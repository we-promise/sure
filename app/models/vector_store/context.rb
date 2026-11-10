# Capture the adapter and its ownership together, once per operation. Never
# re-resolve credentials between creating a store and uploading/searching it.
class VectorStore::Context
  attr_reader :adapter

  def initialize(family:, adapter:, family_configured: false, credential_fingerprint: nil)
    @family = family
    @adapter = adapter
    @family_configured = family_configured
    @credential_fingerprint = credential_fingerprint
    @legacy_store_id = family.vector_store_id unless family_configured
  end

  def store_id
    family_configured? ? document_store&.provider_store_id : @legacy_store_id
  end

  def family_document_store
    document_store if family_configured?
  end

  def family_configured?
    @family_configured
  end

  def ensure_store!
    return unless adapter

    # Serializes simultaneous first uploads (including installation-managed
    # stores) and the settings save. The captured adapter stays unchanged even
    # if settings rotate before or after this lock. The first remote create
    # holds this row lock until its bounded provider timeout; later uploads
    # release the lock before sending file content.
    family.with_lock do
      if family_configured?
        @document_store = family.document_stores.find_or_create_by!(provider: "openai", credential_fingerprint: @credential_fingerprint)
      else
        @legacy_store_id = family.vector_store_id
      end
      return store_id if store_id.present?

      response = adapter.create_store(name: "Family #{family.id} Documents")
      return unless response.success? && response.data[:id].present?

      created_id = response.data[:id]
      begin
        if family_configured?
          @document_store.update!(provider_store_id: created_id)
        else
          family.update!(vector_store_id: created_id)
          @legacy_store_id = created_id
        end
      rescue ActiveRecord::ActiveRecordError
        # Only clean up the store this operation just created with this adapter.
        adapter.delete_store(store_id: created_id) rescue nil
        raise
      end
      created_id
    end
  end

  def owns_document?(document)
    return false unless adapter && store_id.present? && document.family_id == family.id

    if family_configured?
      document.family_document_store_id.present? && document.family_document_store_id == document_store&.id
    else
      document.family_document_store_id.nil?
    end
  end

  private
    attr_reader :family

    def document_store
      return if @credential_fingerprint.blank?

      @document_store ||= family.document_stores.find_by(provider: "openai", credential_fingerprint: @credential_fingerprint)
    end
end
