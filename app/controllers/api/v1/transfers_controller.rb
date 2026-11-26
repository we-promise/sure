# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  # entries.amount is numeric(19, 4): at most 15 digits before the point.
  MAX_AMOUNT = BigDecimal("999999999999999.9999")
  private_constant :MAX_AMOUNT

  InvalidParam = Class.new(StandardError)
  private_constant :InvalidParam

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create
  before_action :reject_guest_writes!, only: :create
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
    raise InvalidParam, "transfer must be an object" unless params.require(:transfer).is_a?(ActionController::Parameters)

    details = transfer_params
    raise InvalidParam, "from_account_id and to_account_id are required" unless details[:from_account_id].present? && details[:to_account_id].present?

    family = current_resource_owner.family
    amount = parse_number(:amount, details[:amount], required: true, greater_than: 0, decimals: 4)
    source_fee_amount = parse_number(:source_fee_amount, details[:source_fee_amount], minimum: 0, decimals: 4)
    destination_fee_amount = parse_number(:destination_fee_amount, details[:destination_fee_amount], minimum: 0, decimals: 4)
    exchange_rate = parse_number(:exchange_rate, details[:exchange_rate], greater_than: 0)
    date = parse_transfer_date(details[:date])
    tag_ids = parse_tag_ids(family)
    key = parse_idempotency_key

    accounts = family.accounts.writable_by(current_resource_owner).visible
    source_account = accounts.find(details[:from_account_id])
    destination_account = accounts.find(details[:to_account_id])

    @transfer = Transfer::Creator.new(
      family: family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: date,
      amount: amount,
      exchange_rate: exchange_rate,
      source_fee_amount: source_fee_amount,
      destination_fee_amount: destination_fee_amount,
      tag_ids: tag_ids,
      idempotency_key: key
    ).create

    render :show, status: @transfer.previously_new_record? ? :created : :ok
  rescue InvalidParam => e
    render_validation_error(e.message)
  rescue Transfer::Creator::StaleIdempotencyKeyError
    render_json({
      error: "idempotency_key_conflict",
      message: "idempotency_key was already used for a different transfer"
    }, status: :conflict)
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue ActiveRecord::RangeError
    # amount * exchange_rate can overflow numeric(19, 4) even when each input fits.
    render_validation_error("amount (after applying exchange_rate) is out of range")
  rescue Money::ConversionError => e
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

    # A finite decimal below the stored range (numeric(19, 4)), or nil when the
    # param is absent and not required. String#to_d would read "abc" as 0 and
    # a fourth-decimal-place amount of 0.00001 would be stored as 0.
    def parse_number(key, raw, required: false, greater_than: nil, minimum: nil, decimals: nil)
      if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
        raise InvalidParam, "#{key} is required" if required
        return nil
      end

      value = parse_decimal(raw)
      raise InvalidParam, "#{key} must be a number" unless value
      raise InvalidParam, "#{key} must be no larger than #{MAX_AMOUNT.to_s('F')}" if value.abs > MAX_AMOUNT
      raise InvalidParam, "#{key} can have at most #{decimals} decimal places" if decimals && value != value.round(decimals)
      raise InvalidParam, "#{key} must be greater than #{greater_than}" if greater_than && value <= greater_than
      raise InvalidParam, "#{key} must be at least #{minimum}" if minimum && value < minimum

      value
    end

    def parse_transfer_date(raw)
      return Date.current if raw.blank?

      parse_date(raw) || raise(InvalidParam, "date must be an ISO 8601 date (YYYY-MM-DD)")
    end

    # Read from the raw params because permit drops anything that is not an
    # array of scalars, which would otherwise leave the transfer untagged
    # without an error.
    def parse_tag_ids(family)
      raw = params[:transfer][:tag_ids]
      return [] if raw.nil?

      unless raw.is_a?(Array) && raw.all? { |id| id.is_a?(String) && valid_uuid?(id) }
        raise InvalidParam, "tag_ids must be an array of tag ids"
      end

      ids = raw.uniq
      raise InvalidParam, "tag_ids includes a tag that does not exist" unless family.tags.where(id: ids).count == ids.size

      ids
    end

    # Absent means "no retry protection requested". A key that is present but
    # not a UUID string is rejected rather than dropped: the caller believes
    # retries are safe, and silently ignoring it would let one duplicate the
    # transfer. Read from raw params because permit filters out non-scalars.
    def parse_idempotency_key
      key = params[:transfer][:idempotency_key]
      return nil if key.nil?
      return key if key.is_a?(String) && valid_uuid?(key)

      raise InvalidParam, "idempotency_key must be a UUID"
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
