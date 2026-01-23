# Override Active Storage blob serving to enforce authorization
Rails.application.config.to_prepare do
  module ActiveStorageAttachmentAuthorization
    extend ActiveSupport::Concern

    included do
      include Authentication
      before_action :authorize_transaction_attachment, if: :transaction_attachment?
    end

    private

      def authorize_transaction_attachment
        attachment = ActiveStorage::Attachment.find_by(blob: authorized_blob)
        return unless attachment&.record_type == "Transaction"

        transaction = attachment.record

        # Check if current user has access to this transaction's family
        unless Current.family == transaction.entry.account.family
          raise ActiveRecord::RecordNotFound
        end
      end

      def transaction_attachment?
        return false unless authorized_blob

        attachment = ActiveStorage::Attachment.find_by(blob: authorized_blob)
        attachment&.record_type == "Transaction"
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
