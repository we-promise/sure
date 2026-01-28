class TransactionAttachmentsController < ApplicationController
  before_action :set_transaction
  before_action :set_attachment, only: [ :show, :destroy ]

  def show
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(@attachment, disposition: disposition)
  end

  def create
    attachments = attachment_params

    if attachments.present?
      # Check attachment count limit before attaching
      current_count = @transaction.attachments.size
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

      if @transaction.valid?
        count = new_count
        message = count == 1 ? t("transactions.attachments.uploaded_one") : t("transactions.attachments.uploaded_many", count: count)
        respond_to do |format|
          format.html { redirect_back_or_to transaction_path(@transaction), notice: message }
          format.turbo_stream { flash.now[:notice] = message }
        end
      else
        # Remove invalid attachments
        newly_added = Array(attachment_proxy).reject { |a| existing_ids.include?(a.id) }
        newly_added.each(&:purge)
        error_messages = @transaction.errors.full_messages_for(:attachments).join(", ")
        respond_to do |format|
          format.html { redirect_back_or_to transaction_path(@transaction), alert: t("transactions.attachments.failed_upload", error: error_messages) }
          format.turbo_stream { flash.now[:alert] = t("transactions.attachments.failed_upload", error: error_messages) }
        end
      end
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
    @attachment.purge
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
      @transaction = Current.family.transactions.find(params[:transaction_id])
    end

    def set_attachment
      @attachment = @transaction.attachments.find(params[:id])
    end

    def attachment_params
      if params.has_key?(:attachments)
        Array(params.require(:attachments)).reject(&:blank?).map do |param|
          param.respond_to?(:permit) ? param.permit(:file, :filename, :content_type, :description, :metadata) : param
        end
      elsif params.has_key?(:attachment)
        param = params.require(:attachment)
        return nil if param.blank?
        param.respond_to?(:permit) ? param.permit(:file, :filename, :content_type, :description, :metadata) : param
      end
    end
end
