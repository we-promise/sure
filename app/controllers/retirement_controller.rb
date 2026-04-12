class RetirementController < ApplicationController
  before_action :set_retirement_config, only: %i[show edit update]
  before_action :require_retirement_config, only: %i[add_pension_entry destroy_pension_entry]

  def show
    @pension_entries = @retirement_config.pension_entries_with_gains
  end

  def setup
    @retirement_config = Current.family.retirement_config || Current.family.build_retirement_config(
      birth_year: 1990,
      currency: Current.family.currency
    )
  end

  def create
    # Guard against duplicate creation (unique index on family_id)
    if Current.family.retirement_config
      redirect_to retirement_path
      return
    end

    @retirement_config = Current.family.build_retirement_config(retirement_config_params)

    if @retirement_config.save
      redirect_to retirement_path, notice: t(".created")
    else
      render :setup, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @retirement_config.update(retirement_config_params)
      redirect_to retirement_path, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def add_pension_entry
    @pension_entry = @retirement_config.pension_entries.build(pension_entry_params)

    if @pension_entry.save
      redirect_to retirement_path, notice: t(".pension_entry_added")
    else
      @pension_entries = @retirement_config.pension_entries_with_gains
      render :show, status: :unprocessable_entity
    end
  end

  def destroy_pension_entry
    @pension_entry = @retirement_config.pension_entries.find(params[:id])
    @pension_entry.destroy!
    redirect_to retirement_path, notice: t(".pension_entry_removed")
  end

  private

    def set_retirement_config
      @retirement_config = Current.family.retirement_config

      unless @retirement_config
        redirect_to setup_retirement_path
      end
    end

    def require_retirement_config
      @retirement_config = Current.family.retirement_config

      unless @retirement_config
        redirect_to setup_retirement_path, alert: t("retirement.show.setup_required")
      end
    end

    def retirement_config_params
      params.require(:retirement_config).permit(
        :country, :pension_system, :birth_year, :retirement_age,
        :target_monthly_income, :currency, :expected_return_pct,
        :inflation_pct, :tax_rate_pct, :current_monthly_savings,
        :contribution_start_year, :expected_annual_points, :rentenwert
      )
    end

    # Params are scoped under :pension_entry because the form uses
    # form_with url: ..., scope: :pension_entry. Switching to form_with model:
    # would change the nesting — update this permit list accordingly.
    def pension_entry_params
      params.require(:pension_entry).permit(
        :recorded_at, :current_points, :current_monthly_pension,
        :projected_monthly_pension, :notes
      )
    end
end
