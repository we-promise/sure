# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  def show
    render json: user_response
  end

  def update
    if current_user.update(user_params)
      render json: user_response
    else
      render json: { error: "validation_failed", messages: current_user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

    def user_params
      params.require(:user).permit(
        :first_name, :last_name, :default_period, :locale,
        family_attributes: [ :month_start_day, :id ]
      )
    end

    def user_response
      {
        id: current_user.id,
        email: current_user.email,
        first_name: current_user.first_name,
        last_name: current_user.last_name,
        default_period: current_user.default_period,
        locale: current_user.locale,
        family: {
          id: current_user.family.id,
          name: current_user.family.name,
          currency: current_user.family.currency,
          timezone: current_user.family.timezone,
          date_format: current_user.family.date_format,
          country: current_user.family.country,
          month_start_day: current_user.family.month_start_day
        }
      }
    end
end
