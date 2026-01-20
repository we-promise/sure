# frozen_string_literal: true

module Api
  module V1
    class UsersController < BaseController
      def me
        user = current_resource_owner

        render json: {
          id: user.id.to_s,
          email: user.email,
          name: [user.first_name, user.last_name].compact.join(" "),
          created_at: user.created_at.iso8601
        }
      end
    end
  end
end
