module TurboNative
  module Controller
    extend ActiveSupport::Concern

    TURBO_NATIVE_USER_AGENT = /Turbo\s?Native/i
    TURBO_NATIVE_HEADER = "Turbo-Native"
    TURBO_VISIT_CONTROL_HEADER = "Turbo-Visit-Control"

    included do
      before_action :set_turbo_native_variant
      helper_method :turbo_native_app?
    end

    private
      def set_turbo_native_variant
        request.variant = :turbo_native if turbo_native_app?
      end

      def turbo_native_app?
        return @turbo_native_app unless @turbo_native_app.nil?

        @turbo_native_app = turbo_native_user_agent? ||
          request.headers[TURBO_NATIVE_HEADER].present? ||
          request.headers[TURBO_VISIT_CONTROL_HEADER] == "native"
      end

      def turbo_native_user_agent?
        user_agent = request.user_agent.to_s
        user_agent.match?(TURBO_NATIVE_USER_AGENT)
      end
  end
end
