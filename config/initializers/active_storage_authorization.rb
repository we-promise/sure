# Override Active Storage blob serving to enforce authorization
Rails.application.config.to_prepare do
  # Monkey patch Active Storage to check authorization for transaction attachments
  ActiveStorage::Blobs::RedirectController.class_eval do
    before_action :authorize_transaction_attachment, if: :transaction_attachment?

    private

      def authorize_transaction_attachment
        attachment = ActiveStorage::Attachment.find_by(blob: @blob)
        return unless attachment&.record_type == "Transaction"

        transaction = attachment.record

        # Check if current user has access to this transaction's family
        unless Current.family == transaction.entry.account.family
          raise ActiveRecord::RecordNotFound
        end
      end

      def transaction_attachment?
        return false unless @blob

        attachment = ActiveStorage::Attachment.find_by(blob: @blob)
        attachment&.record_type == "Transaction"
      end
  end

  ActiveStorage::Blobs::ProxyController.class_eval do
    before_action :authorize_transaction_attachment, if: :transaction_attachment?

    private

      def authorize_transaction_attachment
        attachment = ActiveStorage::Attachment.find_by(blob: @blob)
        return unless attachment&.record_type == "Transaction"

        transaction = attachment.record

        # Check if current user has access to this transaction's family
        unless Current.family == transaction.entry.account.family
          raise ActiveRecord::RecordNotFound
        end
      end

      def transaction_attachment?
        return false unless @blob

        attachment = ActiveStorage::Attachment.find_by(blob: @blob)
        attachment&.record_type == "Transaction"
      end
  end
end
