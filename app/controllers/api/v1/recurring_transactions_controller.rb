# frozen_string_literal: true

class Api::V1::RecurringTransactionsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy]
  before_action :set_readable_recurring_transaction, only: :show
  before_action :set_writable_recurring_transaction, only: %i[update destroy]

  def index
    return render_invalid_account_filter if params[:account_id].present? && !valid_uuid?(params[:account_id])

    @per_page = safe_per_page_param
    recurring_transactions_query = read_recurring_transactions_scope
      .includes(:account, :merchant)
      .order(status: :asc, next_expected_date: :asc)

    recurring_transactions_query = apply_filters(recurring_transactions_query)

    @pagy, @recurring_transactions = pagy(
      recurring_transactions_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "RecurringTransactionsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Internal server error"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "RecurringTransactionsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Internal server error"
    }, status: :internal_server_error
  end

  def create
    @recurring_transaction = current_resource_owner.family.recurring_transactions.new(
      recurring_transaction_create_attributes
    )
    validate_create_write_params(@recurring_transaction)

    if @recurring_transaction.errors.empty? && @recurring_transaction.save
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Recurring transaction could not be created",
        errors: @recurring_transaction.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActionController::ParameterMissing, ArgumentError => e
    render json: {
      error: "validation_failed",
      message: e.message
    }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: {
      error: "conflict",
      message: "Recurring transaction already exists"
    }, status: :conflict
  rescue => e
    Rails.logger.error "RecurringTransactionsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Internal server error"
    }, status: :internal_server_error
  end

  def update
    @recurring_transaction.assign_attributes(recurring_transaction_update_attributes)
    validate_update_write_params(@recurring_transaction)

    if @recurring_transaction.errors.empty? && @recurring_transaction.save
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Recurring transaction could not be updated",
        errors: @recurring_transaction.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActionController::ParameterMissing, ArgumentError => e
    render json: {
      error: "validation_failed",
      message: e.message
    }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: {
      error: "conflict",
      message: "Recurring transaction already exists"
    }, status: :conflict
  rescue => e
    Rails.logger.error "RecurringTransactionsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Internal server error"
    }, status: :internal_server_error
  end

  def destroy
    @recurring_transaction.destroy!

    render json: { message: "Recurring transaction deleted successfully" }, status: :ok
  rescue ActiveRecord::RecordNotFound
    raise
  rescue => e
    Rails.logger.error "RecurringTransactionsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Internal server error"
    }, status: :internal_server_error
  end

  private
    def set_readable_recurring_transaction
      @recurring_transaction = find_recurring_transaction(read_recurring_transactions_scope)
    end

    def set_writable_recurring_transaction
      @recurring_transaction = find_recurring_transaction(write_recurring_transactions_scope)
    end

    def find_recurring_transaction(scope)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      scope.includes(:account, :merchant).find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def read_recurring_transactions_scope
      current_resource_owner.family.recurring_transactions.accessible_by(current_resource_owner)
    end

    def write_recurring_transactions_scope
      scope = current_resource_owner.family.recurring_transactions
      writable_account_ids = current_resource_owner.family.accounts.writable_by(current_resource_owner).select(:id)
      scope.where(account_id: writable_account_ids).or(scope.where(account_id: nil))
    end

    def apply_filters(query)
      query = query.where(status: params[:status]) if params[:status].present?
      if params[:account_id].present?
        return query.none unless valid_uuid?(params[:account_id])

        query = query.where(account_id: params[:account_id])
      end
      query
    end

    def recurring_transaction_create_attributes
      attrs = recurring_transaction_create_params.to_h.symbolize_keys
      attrs[:manual] = true if attrs[:manual].nil?
      input = recurring_transaction_input

      attrs[:account] = writable_account(input[:account_id]) if input.key?(:account_id)
      attrs[:merchant] = family_merchant(input[:merchant_id]) if input.key?(:merchant_id)

      attrs
    end

    def recurring_transaction_update_attributes
      recurring_transaction_update_params.to_h.symbolize_keys
    end

    def writable_account(account_id)
      return nil if account_id.blank?
      raise ActiveRecord::RecordNotFound, "Account not found" unless valid_uuid?(account_id)

      current_resource_owner.family.accounts.writable_by(current_resource_owner).find_by(id: account_id) ||
        raise(ActiveRecord::RecordNotFound, "Account not found")
    end

    def family_merchant(merchant_id)
      return nil if merchant_id.blank?
      raise ActiveRecord::RecordNotFound, "Merchant not found" unless valid_uuid?(merchant_id)

      current_resource_owner.family.merchants.find_by(id: merchant_id) ||
        raise(ActiveRecord::RecordNotFound, "Merchant not found")
    end

    def validate_create_write_params(recurring_transaction)
      input = recurring_transaction_input
      recurring_transaction.errors.add(:last_occurrence_date, :blank) if input[:last_occurrence_date].blank?
      recurring_transaction.errors.add(:next_expected_date, :blank) if input[:next_expected_date].blank?
    end

    def validate_update_write_params(recurring_transaction)
      input = recurring_transaction_input
      if input.key?(:next_expected_date) && input[:next_expected_date].blank?
        recurring_transaction.errors.add(:next_expected_date, :blank)
      end
    end

    def recurring_transaction_input
      params.require(:recurring_transaction)
    end

    def render_invalid_account_filter
      render json: {
        error: "validation_failed",
        message: "account_id must be a valid UUID"
      }, status: :unprocessable_entity
    end

    def recurring_transaction_create_params
      params.require(:recurring_transaction).permit(
        :name,
        :amount,
        :currency,
        :expected_day_of_month,
        :last_occurrence_date,
        :next_expected_date,
        :status,
        :occurrence_count,
        :manual,
        :expected_amount_min,
        :expected_amount_max,
        :expected_amount_avg
      )
    end

    def recurring_transaction_update_params
      params.require(:recurring_transaction).permit(
        :status,
        :expected_day_of_month,
        :next_expected_date
      )
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
