# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope   # catch-all: every action requires at least read scope
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_writable_account, only: [ :update, :destroy ]

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
    opening_date = parse_opening_balance_date

    type = params.dig(:account, :accountable_type)
    unless Accountable::TYPES.include?(type)
      valid_types = Accountable::TYPES.join(", ")
      return render json: {
        error: "validation_failed",
        message: "accountable_type must be one of: #{valid_types}",
        errors: [ "Accountable type must be one of: #{valid_types}" ]
      }, status: :unprocessable_entity
    end

    @account = Account.create_and_sync(
      account_params_for_create,
      opening_balance_date: opening_date
    )

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Account could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  rescue ArgumentError, RuntimeError => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "AccountsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def update
    if @account.update(account_params_for_update)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Account could not be updated",
        errors: @account.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error "AccountsController#update error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" },
           status: :internal_server_error
  end

  def destroy
    if @account.linked?
      return render json: {
        error: "validation_failed",
        message: "Cannot delete a linked account. Unlink the account from its provider first.",
        errors: [ "Cannot delete a linked account. Unlink the account from its provider first." ]
      }, status: :unprocessable_entity
    end

    @account.destroy_later
    render json: { message: "Account queued for deletion" }, status: :ok
  rescue => e
    Rails.logger.error "AccountsController#destroy error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred" },
           status: :internal_server_error
  end

  private

    def set_writable_account
      unless valid_uuid?(params[:id])
        render json: { error: "not_found", message: "Account not found" }, status: :not_found
        return
      end

      @account = current_resource_owner.family.accounts
                                       .writable_by(current_resource_owner)
                                       .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
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

    def account_params_for_create
      permitted = params.require(:account).permit(
        :name, :balance, :currency, :accountable_type, :subtype
      )

      type = permitted[:accountable_type]
      accountable_attributes = {}
      accountable_attributes[:subtype] = permitted[:subtype] if permitted[:subtype].present?

      if type == "Loan"
        loan_params = params.require(:account).permit(:interest_rate, :term_months, :rate_type)
        accountable_attributes.merge!(loan_params.to_h.symbolize_keys)
      end

      {
        name: permitted[:name],
        balance: permitted[:balance],
        currency: permitted[:currency] || current_resource_owner.family.currency,
        accountable_type: type,
        accountable_attributes: accountable_attributes,
        owner: current_resource_owner,
        family: current_resource_owner.family
      }.compact
    end

    def parse_opening_balance_date
      date_str = params.dig(:account, :opening_balance_date)
      return nil if date_str.blank?

      Date.iso8601(date_str)
    rescue ArgumentError
      raise ArgumentError, "opening_balance_date is not a valid date"
    end

    def account_params_for_update
      params.require(:account).permit(:name, :currency, :subtype)
    end
end
