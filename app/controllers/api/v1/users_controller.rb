module Api
  module V1
    class UsersController < BaseController
      def enable_ai
        user = current_resource_owner

        if user.update(ai_enabled: true)
          render json: { user: mobile_user_payload(user) }
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

        def mobile_user_payload(user)
          {
            id: user.id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            ui_layout: user.ui_layout,
            ai_enabled: user.ai_enabled?
          }
        end
    end
  end
end
