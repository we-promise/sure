class TransactionAttachmentsController < ApplicationController
  before_action :set_transaction
  before_action :set_attachment, only: [ :show, :destroy ]
  before_action :set_permissions, only: [ :create, :destroy ]

  def show
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(@attachment, disposition: disposition)
  end

  def create
    unless @can_upload
      redirect_back_or_to transaction_path(@transaction), alert: t("accounts.not_authorized")
      return
    end

    attachments = attachment_params

    if attachments.present?
      blobs_to_index = []

      @transaction.with_lock do
        # Check attachment count limit before attaching
        current_count = @transaction.attachments.count
        new_count = attachments.is_a?(Array) ? attachments.length : 1

        if current_count + new_count > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
          respond_to do |format|
            format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.cannot_exceed", count: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION) }
            format.turbo_stream { flash.now[:alert] = t("transactions.attachments.cannot_exceed", count: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION) }
          end
          return
        end

        existing_ids = @transaction.attachments.pluck(:id)
        attachment_proxy = @transaction.attachments.attach(attachments)
        newly_added = Array(attachment_proxy).reject { |a| existing_ids.include?(a.id) }

        if @transaction.valid?
          blobs_to_index = newly_added.map(&:blob)
          count = new_count
          message = count == 1 ? t("transactions.attachments.uploaded_one") : t("transactions.attachments.uploaded_many", count: count)
          respond_to do |format|
            format.html { redirect_back_or_to transaction_path(@transaction), notice: message }
            format.turbo_stream { flash.now[:notice] = message }
          end
        else
          # Remove invalid attachments
          newly_added.each(&:purge)
          error_messages = @transaction.errors.full_messages_for(:attachments).join(", ")
          respond_to do |format|
            format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.failed_upload", error: error_messages) }
            format.turbo_stream { flash.now[:alert] = t("transactions.attachments.failed_upload", error: error_messages) }
          end
        end
      end

      # Enqueue vector-store indexing only after the attachments are committed,
      # so the background job can reliably load the persisted blobs.
      enqueue_attachment_indexing(blobs_to_index)
    else
      respond_to do |format|
        format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.no_files_selected") }
        format.turbo_stream { flash.now[:alert] = t("transactions.attachments.no_files_selected") }
      end
    end
  rescue => e
    logger.error "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.upload_failed") }
      format.turbo_stream { flash.now[:alert] = t("transactions.attachments.upload_failed") }
    end
  end

  def destroy
    unless @can_delete
      redirect_back_or_to transaction_path(@transaction), alert: t("accounts.not_authorized")
      return
    end

    family = @transaction.entry.account.family
    blob_id = @attachment.blob_id
    @attachment.purge
    enqueue_attachment_removal(family, blob_id)
    message = t("transactions.attachments.attachment_deleted")
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), notice: message }
      format.turbo_stream { flash.now[:notice] = message }
    end
  rescue => e
    logger.error "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.delete_failed") }
      format.turbo_stream { flash.now[:alert] = t("transactions.attachments.delete_failed") }
    end
  end

  private

    def set_transaction
      @transaction = Current.family.transactions
                       .joins(entry: :account)
                       .merge(Account.accessible_by(Current.user))
                       .find(params[:transaction_id])
    end

    def set_attachment
      @attachment = @transaction.attachments.find(params[:id])
    end

    def set_permissions
      permission = @transaction.entry.account.permission_for(Current.user)
      @can_upload = permission.in?([ :owner, :full_control, :read_write ])
      @can_delete = permission.in?([ :owner, :full_control ])
    end

    def enqueue_attachment_indexing(blobs)
      return if blobs.blank?
      return unless VectorStore.configured?

      blobs.each do |blob|
        IndexTransactionAttachmentJob.perform_later(@transaction, blob)
      end
    end

    def enqueue_attachment_removal(family, blob_id)
      return unless VectorStore.configured?

      RemoveTransactionAttachmentJob.perform_later(family, blob_id)
    end

    def attachment_params
      if params.has_key?(:attachments)
        Array(params.fetch(:attachments, [])).reject(&:blank?).map do |param|
          param.respond_to?(:permit) ? param.permit(:file, :filename, :content_type, :description, :metadata) : param
        end
      elsif params.has_key?(:attachment)
        param = params[:attachment]
        return nil if param.blank?
        param.respond_to?(:permit) ? param.permit(:file, :filename, :content_type, :description, :metadata) : param
      end
    end
end
