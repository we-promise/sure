class Retirement::StatementsController < ApplicationController
  include RetirementScoped

  before_action :set_statement, only: %i[destroy]

  def new
    @statement = @plan.statements.new(
      received_on: Date.current,
      projected_currency: Current.family.primary_currency_code
    )
    @pension_sources = @plan.pension_sources.order(:start_age)
  end

  def create
    @statement = @plan.statements.new(statement_params)
    if @statement.save
      redirect_to retirement_path, notice: t(".created")
    else
      @pension_sources = @plan.pension_sources.order(:start_age)
      render :new, status: :unprocessable_entity
    end
  end

  # Append-only audit: deleting flips the soft-delete flag so history is kept.
  def destroy
    @statement.update!(deleted: true)
    redirect_to retirement_path, notice: t(".deleted")
  end

  private
    def set_statement
      @statement = @plan.statements.find(params[:id])
    end

    def statement_params
      params.require(:goal_retirement_statement).permit(
        :pension_source_id, :received_on, :projected_monthly_amount,
        :projected_currency, :projected_at_age, :current_points,
        :raw_source_doc, :notes
      )
    end
end
