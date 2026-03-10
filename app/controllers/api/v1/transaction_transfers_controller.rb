# frozen_string_literal: true

class Api::V1::TransactionTransfersController < Api::V1::BaseController
  before_action :set_transaction

  # PATCH /api/v1/transactions/:transaction_id/transfer
  #
  # Links two transactions together as a transfer.
  # Accepts { transfer: { other_transaction_id: "<uuid>" } } in the request body.
  def update
    return unless authorize_scope!(:write)

    other_transaction_id = transfer_params[:other_transaction_id]

    unless other_transaction_id.present?
      render json: {
        error: "validation_failed",
        message: "other_transaction_id is required",
        errors: [ "other_transaction_id is required" ]
      }, status: :unprocessable_entity
      return
    end

    family = current_resource_owner.family
    other_transaction = family.transactions.find(other_transaction_id)

    if @transaction.transfer.present?
      render json: {
        error: "validation_failed",
        message: "Transaction is already linked to a transfer",
        errors: [ "Transaction is already linked to a transfer" ]
      }, status: :unprocessable_entity
      return
    end

    if other_transaction.transfer.present?
      render json: {
        error: "validation_failed",
        message: "Other transaction is already linked to a transfer",
        errors: [ "Other transaction is already linked to a transfer" ]
      }, status: :unprocessable_entity
      return
    end

    transfer = Transfer.link!(@transaction, other_transaction)

    @transaction = @transaction.reload
    render :show, status: :ok

  rescue ActionController::ParameterMissing
    render json: {
      error: "validation_failed",
      message: "other_transaction_id is required",
      errors: [ "other_transaction_id is required" ]
    }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Transaction not found"
    }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "TransactionTransfersController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def set_transaction
      family = current_resource_owner.family
      @transaction = family.transactions.find(params[:transaction_id])
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    def transfer_params
      params.require(:transfer).permit(:other_transaction_id)
    end
end
