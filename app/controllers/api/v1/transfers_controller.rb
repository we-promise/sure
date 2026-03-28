# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  before_action -> { authorize_scope!(:read_write) }

  def create
    family = current_resource_owner.family

    @transfer = Transfer::Creator.new(
      family: family,
      source_account_id: transfer_params[:source_account_id],
      destination_account_id: transfer_params[:destination_account_id],
      date: Date.parse(transfer_params[:date]),
      amount: transfer_params[:amount].to_d
    ).create

    if @transfer.persisted?
      render json: transfer_json(@transfer), status: :created
    else
      render json: { error: @transfer.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Account not found" }, status: :not_found
  rescue Date::Error, TypeError
    render json: { error: "Invalid date format. Use YYYY-MM-DD." }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "TransfersController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  private

    def transfer_params
      params.require(:transfer).permit(:source_account_id, :destination_account_id, :date, :amount)
    end

    def transfer_json(transfer)
      {
        id: transfer.id,
        source_account: {
          id: transfer.from_account&.id,
          name: transfer.from_account&.name
        },
        destination_account: {
          id: transfer.to_account&.id,
          name: transfer.to_account&.name
        },
        date: transfer.date,
        amount: transfer.amount_abs&.amount&.to_s,
        status: transfer.status,
        created_at: transfer.created_at,
        updated_at: transfer.updated_at
      }
    end
end
