# Override Active Storage blob serving to enforce authorization
Rails.application.config.to_prepare do
  module ActiveStorageAttachmentAuthorization
    extend ActiveSupport::Concern

    included do
      include Authentication
      before_action :authorize_protected_attachment, if: :protected_attachment?
    end

    private

      def authorize_protected_attachment
        attachment = authorized_attachment
        return unless attachment

        case attachment.record_type
        when "Transaction"
          authorize_transaction_attachment(attachment)
        when "AccountStatement"
          authorize_account_statement_attachment(attachment)
        end
      end

      def authorize_transaction_attachment(attachment)
        transaction = attachment.record

        # Check if current user has access to this transaction's family
        unless Current.family == transaction.entry.account.family
          raise ActiveRecord::RecordNotFound
        end
      end

      def authorize_account_statement_attachment(attachment)
        statement = attachment.record
        allowed =
          Current.family == statement.family &&
          (statement.account.nil? || statement.account.shared_with?(Current.user))

        raise ActiveRecord::RecordNotFound unless allowed
      end

      def protected_attachment?
        authorized_attachment&.record_type.in?([ "Transaction", "AccountStatement" ])
      end

      def authorized_attachment
        return nil unless authorized_blob

        @authorized_attachment ||= ActiveStorage::Attachment.find_by(blob: authorized_blob)
      end

      def authorized_blob
        @blob || @representation&.blob
      end
  end

  [
    ActiveStorage::Blobs::RedirectController,
    ActiveStorage::Blobs::ProxyController,
    ActiveStorage::Representations::RedirectController,
    ActiveStorage::Representations::ProxyController
  ].each do |controller|
    controller.include ActiveStorageAttachmentAuthorization
  end
end
