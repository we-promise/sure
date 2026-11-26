# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  # entries.amount is numeric(19, 4): at most 15 digits before the point.
  MAX_AMOUNT = BigDecimal("999999999999999.9999")
  private_constant :MAX_AMOUNT

  InvalidParam = Class.new(StandardError)
  private_constant :InvalidParam

  # Ruby also reads "1_000" as 1000, so the shape is checked before converting.
  NUMBER_FORMAT = /\A[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\z/
  private_constant :NUMBER_FORMAT

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

  # Sending the same idempotency_key (a UUID) again returns the transfer it
  # already created.
  def create
    from_account_id = parse_uuid(:from_account_id, required: true)
    to_account_id = parse_uuid(:to_account_id, required: true)

    family = current_resource_owner.family
    amount = parse_number(:amount, required: true, greater_than: 0)
    source_fee_amount = parse_number(:source_fee_amount, minimum: 0)
    destination_fee_amount = parse_number(:destination_fee_amount, minimum: 0)
    exchange_rate = parse_number(:exchange_rate, greater_than: 0, decimals: nil)
    date = parse_transfer_date
    key = parse_uuid(:idempotency_key)
    tag_ids = parse_tag_ids(family)

    accounts = family.accounts.writable_by(current_resource_owner).visible
    source_account = accounts.find(from_account_id)
    destination_account = accounts.find(to_account_id)
    if exchange_rate && source_account.currency == destination_account.currency
      raise InvalidParam, "exchange_rate only applies when the accounts use different currencies"
    end

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
  rescue InvalidParam, Money::ConversionError => e
    render_validation_error(e.message)
  rescue Transfer::Creator::StaleIdempotencyKeyError
    render_json({
      error: "idempotency_key_conflict",
      message: "idempotency_key was already used for a different transfer"
    }, status: :conflict)
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence)
  rescue ActiveRecord::RangeError
    # amount * exchange_rate can overflow numeric(19, 4) even when each input fits.
    render_validation_error("amount (after applying exchange_rate) is out of range")
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    # The raw request, checked to be an object. Nothing goes through `permit`,
    # which would drop an array or object from a one-value field without a word.
    def transfer_params
      @transfer_params ||= begin
        transfer = params.require(:transfer)
        raise InvalidParam, "transfer must be an object" unless transfer.is_a?(ActionController::Parameters)

        transfer
      end
    end

    # null and "" both mean the field was left out.
    def omitted?(raw)
      raw.to_s.strip.empty?
    end

    # A finite decimal within numeric(19, 4), or nil when the param is absent
    # and not required. Too many decimal places are rejected rather than
    # rounded: a retry is matched against the amount as sent, so a rounded
    # amount would never match the stored one.
    def parse_number(key, required: false, greater_than: nil, minimum: nil, decimals: 4)
      raw = transfer_params[key]
      if omitted?(raw)
        raise InvalidParam, "#{key} is required" if required
        return nil
      end

      raise InvalidParam, "#{key} has more digits than a JSON number can carry; send it as a string" if rounded_float?(raw)

      text = raw.to_s.strip
      value = parse_decimal(text) if (raw.is_a?(String) || raw.is_a?(Numeric)) && text.match?(NUMBER_FORMAT)
      raise InvalidParam, "#{key} must be a number" unless value
      raise InvalidParam, "#{key} must be no larger than #{MAX_AMOUNT.to_s('F')}" if value.abs > MAX_AMOUNT
      raise InvalidParam, "#{key} can have at most #{decimals} decimal places" if decimals && value != value.round(decimals)
      raise InvalidParam, "#{key} must be greater than #{greater_than}" if greater_than && value <= greater_than
      raise InvalidParam, "#{key} must be at least #{minimum}" if minimum && value < minimum

      value
    end

    # A JSON number is read as a Float, which holds about 15 digits exactly.
    # A longer one has already been rounded by the time it gets here.
    def rounded_float?(raw)
      raw.is_a?(Float) && raw.to_s.sub(/e.*/i, "").delete("-.").sub(/\A0+/, "").length > 15
    end

    # nil when the date was left out: Transfer::Creator then uses today for a
    # new transfer, and for a retry the day the first request was made.
    def parse_transfer_date
      raw = transfer_params[:date]
      return if omitted?(raw)

      parse_date(raw) || raise(InvalidParam, "date must be an ISO 8601 date (YYYY-MM-DD)")
    end

    # A lowercase UUID string, or nil when the field was left out. A value that
    # is present but not a UUID is rejected, not dropped: for an idempotency_key
    # that would give a caller who thinks retries are safe a duplicate. The case
    # is folded because the Creator compares keys as plain text.
    def parse_uuid(key, required: false)
      raw = transfer_params[key]
      raise InvalidParam, "#{key} is required" if raw.nil? && required
      raise InvalidParam, "#{key} must be a UUID" unless raw.nil? || valid_uuid?(raw)

      raw&.downcase
    end

    def parse_tag_ids(family)
      raw = transfer_params[:tag_ids]
      return [] if raw.nil?

      raise InvalidParam, "tag_ids must be an array of tag ids" unless raw.is_a?(Array) && raw.all? { |id| valid_uuid?(id) }

      id_type = Tag.type_for_attribute(:id)
      ids = raw.map { |id| id_type.cast(id) }.uniq
      raise InvalidParam, "tag_ids includes a tag that does not exist" unless family.tags.where(id: ids).count == ids.size

      ids
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
