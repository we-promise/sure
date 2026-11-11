# Override Active Storage blob serving to enforce authorization
Rails.application.config.to_prepare do
  module ActiveStorageAttachmentAuthorization
    extend ActiveSupport::Concern
    # STI subclasses (PdfImport, SureImport, ...) are stored under their base class, "Import".
    PROTECTED_RECORD_TYPES = %w[Transaction AccountStatement FamilyExport Import FamilyDocument].freeze

    included do
      include Authentication
      before_action :authorize_protected_attachment
    end

    private

      def authorize_protected_attachment
        # Direct uploads create unattached blobs; model/controller code authorizes the later attachment.
        return if is_a?(ActiveStorage::DirectUploadsController)
        return unless authorized_blob

        attachments = authorized_attachments
        raise ActiveRecord::RecordNotFound if attachments.empty?
        # Archived exports belong to no family; ArchivedExportsController releases them by download token only.
        raise ActiveRecord::RecordNotFound if attachments.any? { |attachment| attachment.record_type == "ArchivedExport" }
        # Family exports hold the whole family's data; FamilyExportsController releases them to family admins only.
        raise ActiveRecord::RecordNotFound if attachments.any? { |attachment| attachment.record_type == "FamilyExport" && !family_admin_export?(attachment) }

        protected_attachments = attachments.select { |attachment| attachment.record_type.in?(PROTECTED_RECORD_TYPES) }
        return if protected_attachments.empty?
        return if protected_attachments.all? { |attachment| protected_attachment_authorized?(attachment) }

        raise ActiveRecord::RecordNotFound
      end

      def protected_attachment_authorized?(attachment)
        case attachment.record_type
        when "Transaction"
          transaction_attachment_authorized?(attachment)
        when "AccountStatement"
          account_statement_attachment_authorized?(attachment)
        when "FamilyExport"
          family_export_attachment_authorized?(attachment)
        when "Import"
          import_attachment_authorized?(attachment)
        when "FamilyDocument"
          family_record_attachment_authorized?(attachment)
        else
          false
        end
      end

      # Mirrors TransactionAttachmentsController#set_transaction: the account must be shared with the user.
      def transaction_attachment_authorized?(attachment)
        transaction = attachment.record
        return false if transaction.nil?

        account = transaction.entry.account
        account.family_id == Current.family&.id && account.shared_with?(Current.user)
      rescue ActiveRecord::RecordNotFound, NoMethodError
        false
      end

      def account_statement_attachment_authorized?(attachment)
        statement = attachment.record
        return false if statement.nil?

        statement.viewable_by?(Current.user)
      rescue ActiveRecord::RecordNotFound
        false
      end

      # Mirrors FamilyExportsController, which limits exports to family admins.
      def family_export_attachment_authorized?(attachment)
        export = attachment.record
        return false if export.nil?

        export.family_id == Current.family&.id && Current.user.admin?
      rescue ActiveRecord::RecordNotFound, NoMethodError
        false
      end

      # Mirrors ImportsController#set_import: imports linked to a statement follow its visibility.
      def import_attachment_authorized?(attachment)
        import = attachment.record
        return false if import.nil? || import.family_id != Current.family&.id

        import.account_statement.nil? || import.account_statement.viewable_by?(Current.user)
      rescue ActiveRecord::RecordNotFound, NoMethodError
        false
      end

      def family_record_attachment_authorized?(attachment)
        record = attachment.record
        return false if record.nil?

        record.family_id == Current.family&.id
      rescue ActiveRecord::RecordNotFound, NoMethodError
        false
      end

      def authorized_attachments
        return nil unless authorized_blob

        @authorized_attachments ||= attachments_with_sources(authorized_blob)
      end

      def authorized_blob
        @blob || @representation&.blob || disk_service_blob
      end

      def disk_service_blob
        return nil unless is_a?(ActiveStorage::DiskController) && action_name == "show"

        key = decode_verified_key&.fetch(:key, nil)
        return nil if key.blank?

        blob_key = key.to_s[%r{\Avariants/([^/]+)/}, 1] || key
        # A signed key whose blob row is gone (e.g. purged, file not yet deleted) must not bypass the checks.
        ActiveStorage::Blob.find_by!(key: blob_key)
      rescue ActiveStorage::InvalidKeyError
        nil
      end

      # Tracked variants and previews are blobs of their own, attached to an
      # ActiveStorage::VariantRecord or to their source blob. They are authorized
      # through the attachments of the blob they were made from; a variant of a
      # preview is two steps away from its source.
      MAX_DERIVED_BLOB_DEPTH = 2

      def attachments_with_sources(blob, depth = 0)
        ActiveStorage::Attachment.where(blob: blob).to_a.flat_map do |attachment|
          next [ attachment ] unless derived_attachment?(attachment)

          source = derived_source_blob(attachment)
          raise ActiveRecord::RecordNotFound if source.nil? || depth >= MAX_DERIVED_BLOB_DEPTH

          attachments_with_sources(source, depth + 1)
        end
      end

      def derived_attachment?(attachment)
        attachment.record_type == "ActiveStorage::VariantRecord" ||
          (attachment.record_type == "ActiveStorage::Blob" && attachment.name == "preview_image")
      end

      def derived_source_blob(attachment)
        record = attachment.record
        record.is_a?(ActiveStorage::VariantRecord) ? record.blob : record
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def family_admin_export?(attachment)
        export = attachment.record
        return false if export.nil?

        export.family_id == Current.family&.id && Current.user.admin?
      rescue ActiveRecord::RecordNotFound, NoMethodError
        false
      end

      def new_session_url
        Rails.application.routes.url_helpers.new_session_url(active_storage_auth_url_options)
      end

      def new_registration_url
        Rails.application.routes.url_helpers.new_registration_url(active_storage_auth_url_options)
      end

      def active_storage_auth_url_options
        {
          protocol: request.protocol,
          host: request.host,
          port: request.optional_port
        }.compact
      end
  end

  [
    ActiveStorage::Blobs::RedirectController,
    ActiveStorage::Blobs::ProxyController,
    ActiveStorage::Representations::RedirectController,
    ActiveStorage::Representations::ProxyController,
    (ActiveStorage::DiskController if defined?(ActiveStorage::DiskController)),
    (ActiveStorage::DirectUploadsController if defined?(ActiveStorage::DirectUploadsController))
  ].compact.each do |controller|
    controller.include ActiveStorageAttachmentAuthorization
  end
end
