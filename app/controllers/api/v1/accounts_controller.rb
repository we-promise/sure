# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  before_action -> { authorize_scope!(:read) }, only: %i[index show]
  before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
  before_action :set_account, only: %i[show update destroy]

  def index
    family = current_resource_owner.family
    accounts_query = family.accounts.accessible_by(current_resource_owner).visible.alphabetically

    @pagy, @accounts = pagy(
      accounts_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param
    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def show
    render :show
  end

  def create
    family = current_resource_owner.family

    accountable_attrs = {}
    accountable_attrs[:subtype] = account_params[:subtype] if account_params[:subtype].present?

    attributes = {
      family: family,
      name: account_params[:name],
      balance: account_params[:balance] || 0,
      currency: account_params[:currency] || family.currency,
      accountable_type: account_params[:accountable_type],
      accountable_attributes: accountable_attrs
    }

    @account = Account.create_and_sync(attributes, skip_initial_sync: true)
    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "validation_failed", message: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "AccountsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def update
    if account_params[:balance].present?
      result = @account.set_current_balance(account_params[:balance].to_d)
      unless result.success?
        render json: {
          error: "validation_failed",
          message: "Balance could not be updated",
          errors: [ result.error ]
        }, status: :unprocessable_entity
        return
      end
      @account.sync_later
    end

    update_params = account_params.except(:balance, :currency, :accountable_type, :subtype)
    if @account.update(update_params)
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
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  def destroy
    if @account.linked?
      render json: {
        error: "validation_failed",
        message: "Cannot delete linked account. Unlink the account first."
      }, status: :unprocessable_entity
      return
    end

    @account.destroy_later

    render json: { message: "Account deleted successfully" }, status: :ok
  rescue => e
    Rails.logger.error "AccountsController#destroy error: #{e.message}"
    render json: { error: "internal_server_error", message: "Error: #{e.message}" }, status: :internal_server_error
  end

  private

    def set_account
      @account = current_resource_owner.family.accounts.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
    end

    def account_params
      params.require(:account).permit(:name, :accountable_type, :balance, :currency, :subtype, :institution_name)
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      per_page.between?(1, 100) ? per_page : 25
    end
end
