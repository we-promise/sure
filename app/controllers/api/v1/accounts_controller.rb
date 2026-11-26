# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  # accounts.balance and the opening valuation are numeric(19, 4): at most 15
  # digits before the decimal point.
  MAX_BALANCE = BigDecimal("999999999999999.9999")
  private_constant :MAX_BALANCE

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create

  def index
    @per_page = safe_per_page_param

    @pagy, @accounts = pagy(
      accounts_scope.alphabetically,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    unless valid_uuid?(params[:id])
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
      return
    end

    @account = accounts_scope.find(params[:id])

    render :show
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "AccountsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    accountable_class = requested_accountable_class
    unless accountable_class
      render_validation_error("accountable_type must be one of: #{Accountable::TYPES.map(&:underscore).join(', ')}")
      return
    end

    attributes = account_create_params(accountable_class)
    unless attributes[:name].present? && attributes[:balance].present?
      render_validation_error("name and balance are required")
      return
    end

    # Strictly parsed: ActiveRecord would read "1,250.50" as 1 and "abc" as 0,
    # and commit an account with the wrong opening balance.
    attributes[:balance] = parse_balance_param(:balance, attributes[:balance])
    return if performed?

    initial_balance = attributes.dig(:accountable_attributes, :initial_balance)
    if initial_balance.present?
      attributes[:accountable_attributes][:initial_balance] = parse_balance_param(:initial_balance, initial_balance)
      return if performed?
    end

    if attributes[:currency].present?
      attributes[:currency] = Family.normalize_currency_code(attributes[:currency])
      unless attributes[:currency]
        render_validation_error("currency must be a supported ISO 4217 code")
        return
      end
    end

    opening_balance_date = parse_opening_balance_date
    return if performed?

    if loan_balance_would_be_overwritten?(attributes, opening_balance_date)
      render_validation_error(
        "balance must equal initial_balance when the loan's opening date is today: " \
        "the opening balance wins on its own date, so a different balance would be discarded"
      )
      return
    end

    family = current_resource_owner.family
    attributes = attributes.except(:opening_balance_date).merge(
      accountable_type: accountable_class.name,
      currency: attributes[:currency].presence || family.currency,
      owner: current_resource_owner
    )

    Account.transaction do
      @account = family.accounts.create_and_sync(attributes, opening_balance_date: opening_balance_date)
      @account.lock_saved_attributes!
    end

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.presence || e.message)
  rescue => e
    Rails.logger.error "AccountsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    # Accepts "Loan" or "loan" / "credit_card" / "CreditCard".
    def requested_accountable_class
      requested = params.dig(:account, :accountable_type).to_s
      type = Accountable::TYPES.find { |candidate| candidate.underscore == requested.underscore }
      Accountable.from_type(type)
    end

    # Accountable attributes are permitted per type through the same lists the
    # web forms use, so the API cannot set anything the UI cannot.
    def account_create_params(accountable_class)
      permitted = "#{accountable_class.name.pluralize}Controller".constantize.permitted_accountable_attributes

      params.require(:account).permit(
        :name, :balance, :currency, :subtype, :opening_balance_date,
        :institution_name, :institution_domain, :notes, :exclude_from_reports,
        accountable_attributes: permitted
      )
    end

    def parse_opening_balance_date
      raw = params.dig(:account, :opening_balance_date)
      return Time.zone.today - 2.years if raw.blank?

      date = parse_date(raw)
      return date if date

      render_validation_error("opening_balance_date must be an ISO 8601 date (YYYY-MM-DD)")
      nil
    end

    # A finite decimal within the stored range, or a 422 render.
    def parse_balance_param(key, raw)
      value = parse_decimal(raw)
      return value if value && value.abs <= MAX_BALANCE

      render_validation_error("#{key} must be a number no larger than #{MAX_BALANCE.to_s('F')}")
      nil
    end

    # Account.create_and_sync anchors a loan's opening balance on its
    # start_date (else the opening balance date) and, when that is today,
    # cannot also anchor the entered balance, so the initial sync would
    # replace it with initial_balance. Reject the conflict instead of
    # answering 201 with a balance that is about to change.
    def loan_balance_would_be_overwritten?(attributes, opening_balance_date)
      loan_attributes = attributes[:accountable_attributes] || {}
      initial_balance = loan_attributes[:initial_balance]
      return false unless initial_balance.present? && initial_balance != attributes[:balance]

      start_date = parse_date(loan_attributes[:start_date])
      anchor_date = start_date && start_date > Entry.min_supported_date ? start_date : opening_balance_date
      anchor_date >= Date.current
    end

    def render_validation_error(errors)
      errors = Array(errors)
      render json: {
        error: "validation_failed",
        message: errors.to_sentence,
        errors: errors
      }, status: :unprocessable_entity
    end

    def accounts_scope
      scope = current_resource_owner.family.accounts
                                    .accessible_by(current_resource_owner)
                                    .includes(:accountable, account_providers: :provider)
      include_disabled_accounts? ? scope : scope.visible
    end

    def include_disabled_accounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
    end
end
