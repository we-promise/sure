# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend

  before_action -> { authorize_scope!(:read) }, only: %i[index show]
  before_action -> { authorize_scope!(:write) }, only: %i[create update destroy]
  before_action :set_transfer, only: %i[show update destroy]

  def index
    family = current_resource_owner.family
    accessible_account_ids = family.accounts.accessible_by(current_resource_owner).select(:id)

    transfers_query = Transfer
      .joins(inflow_transaction: { entry: :account })
      .where(entries: { account_id: accessible_account_ids })
      .includes(
        inflow_transaction: { entry: :account },
        outflow_transaction: [ :category, { entry: :account } ]
      )
      .order("entries.date DESC")

    # Filter by account (either side of the transfer), scoped to family
    if params[:account_id].present?
      account = family.accounts.accessible_by(current_resource_owner).find_by(id: params[:account_id])
      if account
        transfers_query = transfers_query.where(
          "transfers.inflow_transaction_id IN (SELECT entryable_id FROM entries WHERE account_id = :aid AND entryable_type = 'Transaction')
           OR transfers.outflow_transaction_id IN (SELECT entryable_id FROM entries WHERE account_id = :aid AND entryable_type = 'Transaction')",
          aid: account.id
        )
      else
        transfers_query = transfers_query.none
      end
    end

    # Filter by date range
    if params[:start_date].present?
      transfers_query = transfers_query.where("entries.date >= ?", parse_date!(params[:start_date]))
    end

    if params[:end_date].present?
      transfers_query = transfers_query.where("entries.date <= ?", parse_date!(params[:end_date]))
    end

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param
    render :index
  rescue Date::Error
    render json: { error: "validation_failed", message: "Invalid date format" }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "TransfersController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def show
    render :show
  end

  def create
    family = current_resource_owner.family

    unless transfer_params[:from_account_id].present? && transfer_params[:to_account_id].present?
      return render json: {
        error: "validation_failed",
        message: "from_account_id and to_account_id are required"
      }, status: :unprocessable_entity
    end

    unless transfer_params[:amount].present? && transfer_params[:date].present?
      return render json: {
        error: "validation_failed",
        message: "amount and date are required"
      }, status: :unprocessable_entity
    end

    # Verify both accounts are writable by the current user
    from_account = family.accounts.writable_by(current_resource_owner).find(transfer_params[:from_account_id])
    to_account = family.accounts.writable_by(current_resource_owner).find(transfer_params[:to_account_id])

    @transfer = Transfer::Creator.new(
      family: family,
      source_account_id: from_account.id,
      destination_account_id: to_account.id,
      date: parse_date!(transfer_params[:date]),
      amount: transfer_params[:amount].to_d
    ).create

    if @transfer.persisted?
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Transfer could not be created",
        errors: @transfer.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Account not found" }, status: :not_found
  rescue Date::Error
    render json: { error: "validation_failed", message: "Invalid date format" }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "TransfersController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def update
    if transfer_update_params[:status].present?
      case transfer_update_params[:status]
      when "rejected"
        @transfer.reject!
        return render json: { message: "Transfer rejected" }, status: :ok
      when "confirmed"
        @transfer.confirm!
      else
        return render json: {
          error: "validation_failed",
          message: "Invalid status. Must be 'confirmed' or 'rejected'"
        }, status: :unprocessable_entity
      end
    end

    # Use key? to distinguish "not provided" from "explicitly set to empty/nil"
    if params[:transfer].key?(:notes)
      @transfer.update!(notes: transfer_update_params[:notes])
    end

    if params[:transfer].key?(:category_id) && @transfer.categorizable?
      @transfer.outflow_transaction.update!(category_id: transfer_update_params[:category_id])
    end

    @transfer.reload
    render :show
  rescue StandardError => e
    Rails.logger.error "TransfersController#update error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  def destroy
    @transfer.destroy!

    render json: { message: "Transfer deleted successfully" }, status: :ok
  rescue StandardError => e
    Rails.logger.error "TransfersController#destroy error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" }, status: :internal_server_error
  end

  private

    # Matches the web TransfersController#set_transfer pattern:
    # scopes via inflow_transaction accessibility (the destination account)
    def set_transfer
      family = current_resource_owner.family
      accessible_transaction_ids = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .select(:id)

      @transfer = Transfer
        .where(inflow_transaction_id: accessible_transaction_ids)
        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Transfer not found" }, status: :not_found
    end

    def transfer_params
      params.require(:transfer).permit(:from_account_id, :to_account_id, :amount, :date)
    end

    def transfer_update_params
      params.require(:transfer).permit(:status, :notes, :category_id)
    end

    def parse_date!(date_string)
      Date.parse(date_string)
    rescue Date::Error, ArgumentError, TypeError
      raise Date::Error, "Invalid date format"
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
