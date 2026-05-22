# Override Active Storage blob serving to enforce authorization
Rails.application.config.to_prepare do
  module ActiveStorageAttachmentAuthorization
    extend ActiveSupport::Concern
    PROTECTED_RECORD_TYPES = %w[Transaction AccountStatement].freeze

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
        else
          false
        end
      end

      def transaction_attachment_authorized?(attachment)
        transaction = attachment.record
        return false if transaction.nil?

        Current.family == transaction.entry.account.family
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

      def authorized_attachments
        return nil unless authorized_blob

        @authorized_attachments ||= ActiveStorage::Attachment.where(blob: authorized_blob).to_a
      end

      def authorized_blob
        @blob || @representation&.blob || disk_service_blob
      end

      def disk_service_blob
        return nil unless is_a?(ActiveStorage::DiskController) && action_name == "show"

        key = decode_verified_key&.fetch(:key, nil)
        return nil if key.blank?

        blob_key = key.to_s[%r{\Avariants/([^/]+)/}, 1] || key
        ActiveStorage::Blob.find_by(key: blob_key)
      rescue ActiveStorage::InvalidKeyError
        nil
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
