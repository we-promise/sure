# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  def show
    render json: user_response
  end

  def update
    if Current.user.update(user_params)
      render json: user_response
    else
      render json: { error: "validation_failed", messages: Current.user.errors.full_messages }, status: :unprocessable_entity
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
        id: Current.user.id,
        email: Current.user.email,
        first_name: Current.user.first_name,
        last_name: Current.user.last_name,
        default_period: Current.user.default_period,
        locale: Current.user.locale,
        family: {
          id: Current.family.id,
          name: Current.family.name,
          currency: Current.family.currency,
          timezone: Current.family.timezone,
          date_format: Current.family.date_format,
          country: Current.family.country,
          month_start_day: Current.family.month_start_day
        }
      }
    end
end
