class Retirement::AdjustmentsController < ApplicationController
  include RetirementScoped

  before_action :set_adjustment, only: %i[edit update destroy]

  def new
    @adjustment = @plan.adjustments.new(
      from_age: 65, ordinal: next_ordinal,
      currency: Current.family.primary_currency_code
    )
  end

  def create
    @adjustment = @plan.adjustments.new(adjustment_params)
    if @adjustment.save
      redirect_to retirement_path, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @adjustment.update(adjustment_params)
      redirect_to retirement_path, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @adjustment.destroy!
    redirect_to retirement_path, notice: t(".deleted")
  end

  private
    def set_adjustment
      @adjustment = @plan.adjustments.find(params[:id])
    end

    def next_ordinal
      (@plan.adjustments.maximum(:ordinal) || -1) + 1
    end

    def adjustment_params
      params.require(:goal_retirement_adjustment).permit(
        :label, :from_age, :to_age, :amount_today, :currency, :icon, :ordinal
      )
    end
end
