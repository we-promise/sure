# frozen_string_literal: true

class Api::V1::TransactionTransfersController < Api::V1::BaseController
  before_action :ensure_write_scope
  before_action :set_transaction

  # PATCH /api/v1/transactions/:transaction_id/transfer
  #
  # Links two transactions together as a transfer.
  # Accepts { transfer: { other_transaction_id: "<uuid>" } } in the request body.
  def update
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

    inflow_txn, outflow_txn = assign_inflow_outflow(@transaction, other_transaction)

    transfer = Transfer.new(
      inflow_transaction: inflow_txn,
      outflow_transaction: outflow_txn,
      status: "confirmed"
    )

    Transfer.transaction do
      transfer.save!

      destination_account = transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
      end

      transfer.outflow_transaction.update!(outflow_attrs)
      transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    transfer.sync_account_later

    @transaction = @transaction.reload
    render :show, status: :ok

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

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def transfer_params
      params.require(:transfer).permit(:other_transaction_id)
    end

    # Determine which transaction is inflow (negative amount = receives money)
    # and which is outflow (positive amount = sends money).
    def assign_inflow_outflow(txn_a, txn_b)
      amount_a = txn_a.entry.amount
      amount_b = txn_b.entry.amount

      if amount_a.negative?
        [ txn_a, txn_b ]
      else
        [ txn_b, txn_a ]
      end
    end
end
