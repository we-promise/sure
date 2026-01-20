class TransactionAttachmentsController < ApplicationController
  before_action :set_transaction
  before_action :set_attachment, only: [ :show, :destroy ]

  def show
    redirect_to @attachment.url
  end

  def create
    attachments = attachment_params

    if attachments.present?
      @transaction.attachments.attach(attachments)
      count = attachments.is_a?(Array) ? attachments.length : 1
      message = count == 1 ? "Attachment uploaded successfully" : "#{count} attachments uploaded successfully"
      redirect_back_or_to transaction_path(@transaction), notice: message
    else
      redirect_back_or_to transaction_path(@transaction), alert: "No files selected for upload"
    end
  rescue => e
    redirect_back_or_to transaction_path(@transaction), alert: "Failed to upload attachment: #{e.message}"
  end

  def destroy
    @attachment.purge
    redirect_back_or_to transaction_path(@transaction), notice: "Attachment deleted successfully"
  rescue => e
    redirect_back_or_to transaction_path(@transaction), alert: "Failed to delete attachment: #{e.message}"
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
