# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  def show
    return unless authorize_scope!(:read)

    @user = current_resource_owner
    @family = @user.family
  end

  def update
    return unless authorize_scope!(:write)

    @user = current_resource_owner
    @family = @user.family

    if user_params[:family_attributes].present?
      @family.update!(user_params[:family_attributes].except(:id))
    end

    @user.update!(user_params.except(:family_attributes))

    render :show
  end

  private

    def user_params
      params.permit(
        :default_period, :default_account_order, :theme,
        family_attributes: [ :locale, :date_format, :timezone, :month_start_day, :country ]
      )
    end
end
