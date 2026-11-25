# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  private_constant :UUID_FORMAT

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create
  before_action :set_transfer, only: :show

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  # Moves money between two of the caller's accounts, booking both legs through
  # Transfer::Creator exactly as the web form does. Sending the same
  # idempotency_key (a UUID) again returns the transfer it already created.
  def create
    unless transfer_params[:from_account_id].present? && transfer_params[:to_account_id].present?
      render_validation_error("from_account_id and to_account_id are required")
      return
    end

    amount = parse_amount
    return if performed?

    date = parse_date
    return if performed?

    writable_accounts = current_resource_owner.family.accounts.writable_by(current_resource_owner)
    source_account = writable_accounts.find(transfer_params[:from_account_id])
    destination_account = writable_accounts.find(transfer_params[:to_account_id])

    @transfer = Transfer::Creator.new(
      family: current_resource_owner.family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: date,
      amount: amount,
      exchange_rate: transfer_params[:exchange_rate].presence,
      source_fee_amount: transfer_params[:source_fee_amount],
      destination_fee_amount: transfer_params[:destination_fee_amount],
      tag_ids: transfer_params[:tag_ids],
      idempotency_key: idempotency_key
    ).create

    render :show, status: @transfer.previously_new_record? ? :created : :ok
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue ArgumentError, Money::ConversionError, Transfer::Creator::StaleIdempotencyKeyError => e
    render_validation_error(e.message)
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def transfer_params
      params.require(:transfer).permit(
        :from_account_id, :to_account_id, :amount, :date, :exchange_rate,
        :source_fee_amount, :destination_fee_amount, :idempotency_key, tag_ids: []
      )
    end

    def parse_amount
      amount = BigDecimal(transfer_params[:amount].to_s)
      return amount if amount.positive?

      render_validation_error("amount must be greater than 0")
      nil
    rescue ArgumentError
      render_validation_error("amount is required and must be a positive number")
      nil
    end

    def parse_date
      return Date.current if transfer_params[:date].blank?

      Date.iso8601(transfer_params[:date].to_s)
    rescue Date::Error
      render_validation_error("date must be an ISO 8601 date (YYYY-MM-DD)")
      nil
    end

    def idempotency_key
      key = transfer_params[:idempotency_key]
      key if key.is_a?(String) && key.match?(UUID_FORMAT)
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
