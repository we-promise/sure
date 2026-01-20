# frozen_string_literal: true

module Api
  module V1
    class HealthController < BaseController
      skip_before_action :authenticate_request!
      skip_before_action :check_api_key_rate_limit
      skip_before_action :log_api_access

      def show
        render json: { status: "ok" }
      end
    end
  end
end
