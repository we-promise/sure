# frozen_string_literal: true

class Api::V1::LoansController < Api::V1::BaseController
  before_action :ensure_read_scope
  before_action :set_loan, only: [ :amortization_schedule ]

  # GET /api/v1/loans/:id/amortization_schedule
  # Returns the amortization schedule for a loan with pagination support.
  # Reads from the persisted, indexed amortizations table rather than
  # recomputing (and slicing) the full in-memory schedule on every request,
  # so cost scales with the requested page rather than the loan's term.
  def amortization_schedule
    unless @loan.amortizable?
      return render json: { error: "not_amortizable", message: "Loan is not amortizable" }, status: :unprocessable_entity
    end

    @loan.ensure_amortization_schedule_current!

    limit = safe_per_page_param
    offset = (safe_page_param - 1) * limit

    render :amortization_schedule, locals: {
      loan: @loan,
      schedule: @loan.amortization_schedule,
      payments: @loan.amortizations.ordered.offset(offset).limit(limit),
      total_count: @loan.amortizations.count,
      limit: limit,
      offset: offset
    }
  rescue => e
    log_and_render_error("amortization_schedule", e)
  end

  private

  # Load and authorize the loan, stopping immediately on auth failure.
  # Validates UUID shape before querying so a malformed :id renders a normal
  # 404 instead of an unhandled 500 from an invalid Postgres UUID literal.
  def set_loan
    unless valid_uuid?(params[:id])
      return render json: { error: "not_found", message: "Loan not found" }, status: :not_found
    end

    @loan = Loan.find(params[:id])
    unless authorize_account!(@loan.account)
      render json: { error: "unauthorized", message: "Access denied" }, status: :forbidden
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Loan not found" }, status: :not_found
  end

  # Check if current user can access the given account. Returns boolean instead of rendering.
  def authorize_account!(account)
    current_resource_owner.family.accounts.accessible_by(current_resource_owner).include?(account)
  end

  # Ensure the API key has read scope
  def ensure_read_scope
    authorize_scope!(:read)
  end

  # Extract and validate page number from params. Coerces via to_s first so
  # an array/hash param (e.g. ?page[]=1) can't raise NoMethodError on #to_i.
  def safe_page_param
    page = params[:page].to_s.to_i
    page > 0 ? page : 1
  end

  # Extract and validate per_page from params, clamping to a safe range.
  def safe_per_page_param
    per_page = params[:per_page].to_s.to_i
    return 25 if per_page <= 0
    per_page.clamp(1, 100)
  end

  # Log and render error response
  def log_and_render_error(action, exception)
    Rails.logger.error "LoansController##{action} error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n")
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end
end
