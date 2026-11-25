# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

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

    opening_balance_date = parse_opening_balance_date
    return if performed?

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

      Date.iso8601(raw.to_s)
    rescue Date::Error
      render_validation_error("opening_balance_date must be an ISO 8601 date (YYYY-MM-DD)")
      nil
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
