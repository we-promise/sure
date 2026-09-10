class Api::V1::Financekit::BaseController < Api::V1::BaseController
  wrap_parameters false

  before_action :require_financekit_access
  rescue_from Financekit::Error, with: :protocol_error
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_record
  rescue_from KeyError, with: :invalid_record

  private

    def require_financekit_access
      return unless authorize_scope!(request.get? ? :read : :write)
      unless Current.user.admin? && Current.user.preview_features_enabled?
        raise Financekit::Error.new("publisher_forbidden", 403)
      end
      unless action_name == "capabilities" || Financekit.enabled?(Current.family) || action_name == "destroy"
        raise Financekit::Error.new("unavailable", 503)
      end
    end

    def connection
      @connection ||= Current.family.financekit_items.where(user: Current.user).find(params[:connection_id] || params[:id])
    end

    def input
      request.request_parameters.except("controller", "action")
    end

    def protocol_error(error)
      response.headers["Retry-After"] = "60" if [ 429, 503 ].include?(error.status)
      render_json({ error: error.code }, status: error.status)
    end

    def invalid_record(_error)
      protocol_error(Financekit::Error.new("validation_failed"))
    end
end
