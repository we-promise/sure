# frozen_string_literal: true

# Middleware to catch OmniAuth/OIDC errors and redirect gracefully
# instead of showing ugly error pages
class OmniauthErrorHandler
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue OpenIDConnect::Discovery::DiscoveryFailed => e
    Rails.logger.error("[OmniAuth] OIDC Discovery failed: #{e.message}")
    redirect_to_failure(env, "sso_provider_unavailable")
  rescue OmniAuth::Error => e
    Rails.logger.error("[OmniAuth] Authentication error: #{e.message}")
    redirect_to_failure(env, "sso_failed")
  end

  private

    def redirect_to_failure(env, message)
      [
        302,
        { "Location" => "/auth/failure?message=#{message}", "Content-Type" => "text/html" },
        [ "Redirecting..." ]
      ]
    end
end
