# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  InvalidParam = Class.new(StandardError)
  private_constant :InvalidParam

  NUMERIC_COLUMN_TYPES = %i[integer decimal float].freeze
  private_constant :NUMERIC_COLUMN_TYPES

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create
  before_action :reject_guest_writes!, only: :create

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
    raise InvalidParam, "account must be an object" unless params.require(:account).is_a?(ActionController::Parameters)

    accountable_class = requested_accountable_class
    raise InvalidParam, "accountable_type must be one of: #{Accountable::TYPES.map(&:underscore).join(', ')}" unless accountable_class

    attributes = account_create_params(accountable_class)
    raise InvalidParam, "name and balance are required" unless attributes[:name].present? && attributes[:balance].present?

    family = current_resource_owner.family
    opening_balance_date = parse_opening_balance_date(attributes.delete(:opening_balance_date))
    cast_create_attributes!(accountable_class, attributes, family)
    reject_overwritten_loan_balance!(attributes, opening_balance_date)

    Account.transaction do
      @account = family.accounts.create_and_sync(
        attributes.merge(accountable_type: accountable_class.name, owner: current_resource_owner),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end

    render :show, status: :created
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound
    raise # the base controller answers these with 400 and 404
  rescue InvalidParam, ArgumentError => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence)
  rescue ActiveRecord::RangeError, ActiveModel::RangeError
    render_validation_error("a number is out of range")
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
      Accountable.from_type(requested.underscore.camelize)
    end

    # Accountable attributes are permitted per type through the same lists the
    # web forms use, so the API cannot set anything the UI cannot.
    def account_create_params(accountable_class)
      permitted = "#{accountable_class.name.pluralize}Controller".constantize.permitted_accountable_attributes
      permitted = permitted.reject { |attribute| attribute == :id } # nothing to match on a new account

      params.require(:account).permit(
        :name, :balance, :currency, :subtype, :opening_balance_date,
        :institution_name, :institution_domain, :notes, :exclude_from_reports,
        accountable_attributes: permitted
      )
    end

    def parse_opening_balance_date(raw)
      return Time.zone.today - 2.years if raw.blank?

      date = parse_date(raw)
      raise InvalidParam, "opening_balance_date must be an ISO 8601 date (YYYY-MM-DD)" unless date
      raise InvalidParam, "opening_balance_date cannot be in the future" if date > Date.current

      date
    end

    # Casts the values ActiveRecord would otherwise coerce without complaint:
    # "1,250.50" becomes 1, "abc" becomes 0, a bad start_date becomes nil and
    # quietly falls back to the opening balance date, and an unknown currency
    # is only caught after the account is saved. Everything after this sees
    # numbers, a Date, a known subtype and a valid currency code.
    def cast_create_attributes!(accountable_class, attributes, family)
      attributes[:balance] = parse_number(:balance, attributes[:balance], Account.columns_hash["balance"])

      details = attributes[:accountable_attributes]
      if details
        accountable_class.columns_hash.slice(*details.keys).each do |name, column|
          details[name] = parse_number(name, details[name], column) if NUMERIC_COLUMN_TYPES.include?(column.type) && details[name].present?
        end
        if details[:start_date].present?
          details[:start_date] = parse_date(details[:start_date]) || raise(InvalidParam, "start_date must be an ISO 8601 date (YYYY-MM-DD)")
        end
      end

      reject_unknown_subtype!(accountable_class, attributes[:subtype].presence || details&.dig(:subtype).presence)

      currency = attributes[:currency].present? ? Family.normalize_currency_code(attributes[:currency]) : family.currency
      attributes[:currency] = currency || raise(InvalidParam, "currency must be a supported ISO 4217 code")
    end

    # A whole number or a finite decimal that fits the column.
    def parse_number(name, raw, column)
      value = column.type == :integer ? Integer(raw.to_s.strip, 10, exception: false) : parse_decimal(raw)
      limit = 10**(column.precision - column.scale.to_i) if column.precision

      return value if value && (limit.nil? || value.abs < limit)

      raise InvalidParam, "#{name} must be a #{column.type == :integer ? 'whole ' : ''}number#{" below #{limit}" if limit}"
    end

    def reject_unknown_subtype!(accountable_class, subtype)
      return if subtype.nil? || accountable_class::SUBTYPES.key?(subtype)

      raise InvalidParam, "subtype must be one of: #{accountable_class::SUBTYPES.keys.join(', ')}"
    end

    # Account.create_and_sync anchors an opening balance on the loan's
    # start_date (else the opening balance date) and, when that is today,
    # cannot also anchor the entered balance, so the initial sync would
    # replace it with initial_balance. Reject the conflict instead of
    # answering 201 with a balance that is about to change.
    def reject_overwritten_loan_balance!(attributes, opening_balance_date)
      details = attributes[:accountable_attributes] || {}
      return unless details[:initial_balance].present? && details[:initial_balance] != attributes[:balance]

      start_date = details[:start_date].presence
      anchor_date = start_date && start_date > Entry.min_supported_date ? start_date : opening_balance_date
      return unless anchor_date == Date.current

      raise InvalidParam,
            "balance must equal initial_balance when the opening date is today: " \
            "the opening balance wins on its own date, so a different balance would be discarded"
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
