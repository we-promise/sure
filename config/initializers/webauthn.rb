Rails.application.config.after_initialize do
  WebAuthn.configure do |config|
    default_origin = if Rails.env.production?
      "https://#{ENV.fetch('APP_DOMAIN', 'localhost')}"
    elsif Rails.env.test?
      "https://example.com"
    else
      "http://localhost:#{ENV.fetch('PORT', 3000)}"
    end

    origin = ENV.fetch("WEBAUTHN_ORIGIN", default_origin)
    config.allowed_origins = [ origin ]
    config.rp_name = ENV.fetch("WEBAUTHN_RP_NAME", "Sure")
    config.rp_id = ENV.fetch("WEBAUTHN_RP_ID") { URI.parse(origin).host }
  end
end
