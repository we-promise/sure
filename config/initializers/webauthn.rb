Rails.application.config.after_initialize do
  WebAuthn.configure do |config|
    # Determine the origin based on environment
    # For self-hosted: set WEBAUTHN_ORIGIN to your full URL (e.g., https://myapp.example.com)
    # Or set APP_DOMAIN to just the domain (e.g., myapp.example.com)
    app_domain = ENV.fetch("APP_DOMAIN", nil)

    default_origin = if Rails.env.production?
      app_domain ? "https://#{app_domain}" : "https://localhost"
    elsif Rails.env.test?
      "https://example.com"
    else
      "http://localhost:#{ENV.fetch('PORT', 3000)}"
    end

    origin = ENV.fetch("WEBAUTHN_ORIGIN", default_origin)
    parsed_origin = URI.parse(origin)

    # For WebAuthn, rp_id should be the domain without port
    # It must match the domain users access the site from
    default_rp_id = app_domain || parsed_origin.host

    config.allowed_origins = [ origin ]
    config.rp_name = ENV.fetch("WEBAUTHN_RP_NAME", "Sure")
    config.rp_id = ENV.fetch("WEBAUTHN_RP_ID", default_rp_id)
  end
end
