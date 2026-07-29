class FamiliesController < ApplicationController
  def new
    @family = Family.new(currency: Current.family.currency)
  end

  def create
    @family = Family.new(family_params)

    # Pre-fill other defaults based on the user's current family
    @family.locale = Current.family.locale
    @family.country = Current.family.country
    @family.timezone = Current.family.timezone
    @family.date_format = Current.family.date_format
    @family.month_start_day = Current.family.month_start_day

    Family.transaction do
      if @family.save
        Current.user.family_memberships.create!(
          family: @family,
          role: User.role_for_new_family_creator
        )
        Current.session.set_active_family_id(@family.id)
        redirect_to root_path, notice: t(".success", default: "Ledger created successfully.")
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  private

    def family_params
      params.require(:family).permit(:name, :currency)
    end
end
