# frozen_string_literal: true

class Api::V1::LoansController < Api::V1::BaseController
  MAX_PAGE = 10_000

  before_action :ensure_read_scope
  before_action :set_loan, only: [ :amortization_schedule ]

  # GET /api/v1/loans/:id/amortization_schedule
  # Returns the amortization schedule for a loan with pagination support.
  # Strictly read-only: a read-scoped credential must never trigger a write,
  # so this never calls Loan#ensure_amortization_schedule_current! (which can
  # delete/insert rows). It reads whatever is persisted, reports whether that
  # matches the loan's current inputs via `status`, and enqueues a background
  # rebuild when it doesn't -- the next request (from anyone) picks up the
  # fresh schedule once the job has run.
  def amortization_schedule
    unless @loan.amortizable?
      return render json: { error: "not_amortizable", message: "Loan is not amortizable" }, status: :unprocessable_entity
    end

    status = amortization_schedule_status
    LoanAmortizationRebuildJob.perform_later(@loan.id) unless status == "current"

    limit = safe_per_page_param
    offset = (safe_page_param - 1) * limit

    render :amortization_schedule, locals: {
      loan: @loan,
      status: status,
      payments: @loan.amortizations.ordered.offset(offset).limit(limit),
      total_count: @loan.amortizations.count,
      limit: limit,
      offset: offset
    }
  rescue => e
    log_and_render_error("amortization_schedule", e)
  end

  private

    def amortization_schedule_status
      return "current" if @loan.schedule_current?
      @loan.amortizations.exists? ? "stale" : "missing"
    end

    # Load and authorize the loan in one scoped lookup so an inaccessible
    # loan is indistinguishable from a nonexistent one -- an unscoped find
    # followed by a separate authorization check would return 404 vs 403
    # depending on whether the id merely exists, letting a caller enumerate
    # valid loan ids they don't have access to.
    def set_loan
      unless valid_uuid?(params[:id])
        return render json: { error: "not_found", message: "Loan not found" }, status: :not_found
      end

      @loan = Loan.joins(:account).find_by!(
        id: params[:id],
        accounts: { id: current_resource_owner.family.accounts.accessible_by(current_resource_owner) }
      )
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Loan not found" }, status: :not_found
    end

    # Ensure the API key has read scope
    def ensure_read_scope
      authorize_scope!(:read)
    end

    # Extract and validate page number from params. Coerces via to_s first so
    # an array/hash param (e.g. ?page[]=1) can't raise NoMethodError on #to_i.
    def safe_page_param
      page = Integer(params[:page].to_s, 10)
      page.clamp(1, MAX_PAGE)
    rescue ArgumentError, TypeError
      1
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
