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
      current_count = @transaction.attachments.count
      new_count = attachments.is_a?(Array) ? attachments.length : 1

      if current_count + new_count > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        respond_to do |format|
          format.html { redirect_back_or_to transaction_path(@transaction), alert: "Cannot exceed #{Transaction::MAX_ATTACHMENTS_PER_TRANSACTION} attachments per transaction" }
          format.turbo_stream { flash.now[:alert] = "Cannot exceed #{Transaction::MAX_ATTACHMENTS_PER_TRANSACTION} attachments per transaction" }
        end
        return
      end

      @transaction.attachments.attach(attachments)

      if @transaction.valid?
        count = new_count
        message = count == 1 ? "Attachment uploaded successfully" : "#{count} attachments uploaded successfully"
        respond_to do |format|
          format.html { redirect_back_or_to transaction_path(@transaction), notice: message }
          format.turbo_stream { flash.now[:notice] = message }
        end
      else
        # Remove invalid attachments
        @transaction.attachments.last(new_count).each(&:purge)
        error_messages = @transaction.errors.full_messages_for(:attachments).join(", ")
        respond_to do |format|
          format.html { redirect_back_or_to transaction_path(@transaction), alert: error_messages }
          format.turbo_stream { flash.now[:alert] = error_messages }
        end
      end
    else
      respond_to do |format|
        format.html { redirect_back_or_to transaction_path(@transaction), alert: "No files selected for upload" }
        format.turbo_stream { flash.now[:alert] = "No files selected for upload" }
      end
    end
  rescue => e
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), alert: "Failed to upload attachment: #{e.message}" }
      format.turbo_stream { flash.now[:alert] = "Failed to upload attachment: #{e.message}" }
    end
  end

  def destroy
    @attachment.purge
    message = "Attachment deleted successfully"
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), notice: message }
      format.turbo_stream { flash.now[:notice] = message }
    end
  rescue => e
    message = "Failed to delete attachment: #{e.message}"
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@transaction), alert: message }
      format.turbo_stream { flash.now[:alert] = message }
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
      params[:attachments] || params[:attachment]
    end
end
