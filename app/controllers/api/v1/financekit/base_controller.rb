class Api::V1::Financekit::BaseController < Api::V1::BaseController
  wrap_parameters false

  before_action :require_financekit_access
  rescue_from Financekit::Error, with: :protocol_error
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_record
  rescue_from KeyError, with: :invalid_record

  private

    def require_financekit_access
      return unless authorize_scope!(request.get? ? :read : :write)
      unless current_resource_owner.admin? && current_resource_owner.preview_features_enabled?
        raise Financekit::Error.new("publisher_forbidden", 403)
      end
      unless action_name == "capabilities" || Financekit.enabled?(current_resource_owner.family) || action_name == "destroy"
        raise Financekit::Error.new("unavailable", 503)
      end
    end

    def connection
      @connection ||= current_resource_owner.family.financekit_items.where(user: current_resource_owner).find(params[:connection_id] || params[:id])
    end

    def input
      request.request_parameters
    end

    def protocol_error(error)
      response.headers["Retry-After"] = "60" if [ 429, 503 ].include?(error.status)
      render_json({ error: error.code }, status: error.status)
    end

    def invalid_record(_error)
      protocol_error(Financekit::Error.new("validation_failed"))
    end
end
