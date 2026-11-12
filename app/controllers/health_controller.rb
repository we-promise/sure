# Public dependency probe for an external uptime monitor; see HealthCheck.
# Inherits from ActionController::API, not ApplicationController, so no session,
# authentication, CSRF, onboarding or locale handling runs before it.
class HealthController < ActionController::API
  def show
    errors = begin
      HealthCheck.errors
    rescue => e
      Rails.logger.error("[HealthCheck] crashed: #{e.class}: #{e.message}")
      [ "health: check failed" ]
    end

    no_store
    render json: { errors: errors }, status: errors.empty? ? :ok : :service_unavailable
  end
end
