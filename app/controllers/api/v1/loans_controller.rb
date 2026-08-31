# frozen_string_literal: true

class Api::V1::LoansController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_loan, only: [ :amortization_schedule ]

  def amortization_schedule
    unless @loan.amortizable?
      return render json: { error: "not_amortizable", message: "Loan is not amortizable" }, status: :unprocessable_entity
    end

    schedule = @loan.amortization_schedule
    limit = safe_per_page_param
    offset = (safe_page_param - 1) * limit
    payments = schedule.payments[offset, limit] || []

    render :amortization_schedule, locals: {
      loan: @loan,
      schedule: schedule,
      payments: payments,
      total_count: schedule.payment_count,
      limit: limit,
      offset: offset
    }
  rescue => e
    log_and_render_error("amortization_schedule", e)
  end

  private

  def set_loan
    account = Account.find(params[:account_id])
    authorize_account!(account)
    @loan = account.accountable
    raise ActiveRecord::RecordNotFound unless @loan.is_a?(Loan)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Loan not found" }, status: :not_found
  end

  def authorize_account!(account)
    return if current_resource_owner.family.accounts.accessible_by(current_resource_owner).include?(account)
    render json: { error: "unauthorized", message: "Access denied" }, status: :forbidden
  end

  def ensure_read_scope
    authorize_scope!(:read)
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

  def log_and_render_error(action, exception)
    Rails.logger.error "LoansController##{action} error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n")
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end
end
