# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  # entries.amount is numeric(19, 4): at most 15 digits before the point.
  MAX_AMOUNT = BigDecimal("999999999999999.9999")
  private_constant :MAX_AMOUNT

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

    amount = parse_decimal_param(:amount, required: true, greater_than: 0)
    return if performed?

    source_fee_amount = parse_decimal_param(:source_fee_amount, minimum: 0)
    return if performed?

    destination_fee_amount = parse_decimal_param(:destination_fee_amount, minimum: 0)
    return if performed?

    exchange_rate = parse_decimal_param(:exchange_rate, greater_than: 0)
    return if performed?

    date = parse_transfer_date
    return if performed?

    key = parse_idempotency_key
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
      exchange_rate: exchange_rate,
      source_fee_amount: source_fee_amount,
      destination_fee_amount: destination_fee_amount,
      tag_ids: transfer_params[:tag_ids],
      idempotency_key: key
    ).create

    render :show, status: @transfer.previously_new_record? ? :created : :ok
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue ActiveRecord::RangeError
    # amount * exchange_rate can overflow numeric(19, 4) even when each input fits.
    render_validation_error("amount (after applying exchange_rate) is out of range")
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

    # A finite decimal within the stored range, nil when the param is absent
    # (unless required), or a 422 render. String#to_d would read "abc" as 0.
    def parse_decimal_param(key, required: false, greater_than: nil, minimum: nil)
      raw = transfer_params[key]

      if raw.blank?
        render_validation_error("#{key} is required") if required
        return nil
      end

      value = parse_decimal(raw)
      if value.nil? || value.abs > MAX_AMOUNT
        render_validation_error("#{key} must be a number no larger than #{MAX_AMOUNT.to_s('F')}")
      elsif greater_than && value <= greater_than
        render_validation_error("#{key} must be greater than #{greater_than}")
      elsif minimum && value < minimum
        render_validation_error("#{key} must be at least #{minimum}")
      else
        return value
      end

      nil
    end

    def parse_transfer_date
      return Date.current if transfer_params[:date].blank?

      date = parse_date(transfer_params[:date])
      return date if date

      render_validation_error("date must be an ISO 8601 date (YYYY-MM-DD)")
      nil
    end

    # Absent means "no retry protection requested". A key that is present but
    # not a UUID string is rejected rather than dropped: the caller believes
    # retries are safe, and silently ignoring it would let one duplicate the
    # transfer. Read from raw params because permit filters out non-scalars.
    def parse_idempotency_key
      key = params.require(:transfer)[:idempotency_key]
      return nil if key.nil?
      return key if key.is_a?(String) && valid_uuid?(key)

      render_validation_error("idempotency_key must be a UUID")
      nil
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
