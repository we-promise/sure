class TransactionAttachmentsController < ApplicationController
  before_action :set_transaction
  before_action :set_attachment, only: [ :show, :destroy ]

  def show
    redirect_to @attachment.url
  end

  def create
    @attachment = @transaction.attachments.attach(attachment_params)

    if @attachment
      redirect_back_or_to transaction_path(@transaction), notice: "Attachment uploaded successfully"
    else
      redirect_back_or_to transaction_path(@transaction), alert: "Failed to upload attachment"
    end
  end

  def destroy
    @attachment.purge
    redirect_back_or_to transaction_path(@transaction), notice: "Attachment deleted successfully"
  end

  private

    def set_transaction
      @transaction = Current.family.transactions.find(params[:transaction_id])
    end

    def set_attachment
      @attachment = @transaction.attachments.find(params[:id])
    end

    def attachment_params
      params.require(:attachment)
    end
end
