# frozen_string_literal: true

class Api::V1::ExchangeRatesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: :create
  before_action :ensure_self_hosted_mode, only: :create

  def index
    rates = apply_filters(ExchangeRate.all).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @exchange_rates = pagy(
      rates,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    raise ActiveRecord::RecordNotFound, "Exchange rate not found" unless valid_uuid?(params[:id])

    @exchange_rate = ExchangeRate.find(params[:id])
    render :show
  end

  # Idempotent upsert keyed on (from, to, date): posting the same pair/date
  # again updates the rate instead of failing on the unique index, so clients
  # can safely re-send a full rate history (the workflow this endpoint exists
  # to replace was a cron writing to the table directly).
  def create
    from = normalize_currency!(:from)
    to = normalize_currency!(:to)
    date = normalize_date!
    rate = normalize_rate!

    if from == to
      return render_validation_error("from and to must be different currencies")
    end

    @exchange_rate = upsert_rate(from: from, to: to, date: date, rate: rate)

    render :show, status: @exchange_rate.previously_new_record? ? :created : :ok
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    # The exchange_rates table is global (no family scoping): on managed
    # hosting a write here would change conversions for every family, so
    # manual rate management is limited to self-hosted instances.
    def ensure_self_hosted_mode
      return if Rails.configuration.app_mode.self_hosted?

      render_json({
        error: "forbidden",
        message: "Managing exchange rates is only available on self-hosted instances"
      }, status: :forbidden)
    end

    def apply_filters(query)
      if params[:from].present?
        query = query.where(from_currency: validate_currency!(params[:from], field: "from"))
      end

      if params[:to].present?
        query = query.where(to_currency: validate_currency!(params[:to], field: "to"))
      end

      if params[:start_date].present?
        query = query.where("date >= ?", validate_filter_date!(params[:start_date], field: "start_date"))
      end

      if params[:end_date].present?
        query = query.where("date <= ?", validate_filter_date!(params[:end_date], field: "end_date"))
      end

      query
    end

    def upsert_rate(from:, to:, date:, rate:)
      record = ExchangeRate.find_or_initialize_by(from_currency: from, to_currency: to, date: date)
      record.update!(rate: rate)
      record
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Concurrent POST raced ours between our SELECT and INSERT. The
      # uniqueness *validator* can also lose this race and raise
      # RecordInvalid before the DB's unique index has a chance to raise
      # RecordNotUnique, so both must be treated as "someone else just
      # created it — retry as an update."
      record = ExchangeRate.find_by!(from_currency: from, to_currency: to, date: date)
      record.update!(rate: rate)
      record
    end

    def normalize_currency!(field)
      validate_currency!(params.require(field), field: field)
    end

    def validate_currency!(value, field:)
      code = value.to_s.strip.upcase
      Money::Currency.new(code)
      code
    rescue Money::Currency::UnknownCurrencyError
      raise InvalidFilterError, "#{field} must be a known ISO 4217 currency code"
    end

    def normalize_date!
      validate_filter_date!(params.require(:date), field: "date")
    end

    def validate_filter_date!(value, field:)
      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      raise InvalidFilterError, "#{field} must be a valid date in YYYY-MM-DD format"
    end

    def normalize_rate!
      rate = BigDecimal(params.require(:rate).to_s)
      raise InvalidFilterError, "rate must be greater than 0" unless rate.positive?
      rate
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "rate must be a positive number"
    end
end
