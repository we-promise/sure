class Retirement::PensionSourcesController < ApplicationController
  include RetirementScoped

  before_action :set_source, only: %i[edit update destroy]

  def new
    @source = @plan.pension_sources.new(
      kind: "state", country: "DE", pension_system: "de_grv",
      tax_treatment: "de_renten", payout_shape: "monthly_for_life",
      start_age: 67, currency: Current.family.primary_currency_code
    )
  end

  def create
    @source = @plan.pension_sources.new(source_params)
    if @source.save
      redirect_to retirement_path, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @source.update(source_params)
      redirect_to retirement_path, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @source.destroy!
    redirect_to retirement_path, notice: t(".deleted")
  end

  private
    def set_source
      @source = @plan.pension_sources.find(params[:id])
    end

    def source_params
      params.require(:pension_source).permit(
        :name, :kind, :country, :pension_system, :tax_treatment,
        :payout_shape, :start_age, :end_age, :amount, :currency,
        :effective_rate_override
      )
    end
end
