# frozen_string_literal: true

class Rack::Attack
  # Enable Rack::Attack only in production and staging (disable in test/development to avoid rate-limit flakiness)
  enabled = Rails.env.production? || Rails.env.staging?
  self.enabled = enabled

  # Throttle requests to the OAuth token endpoint
  throttle("oauth/token", limit: 10, period: 1.minute) do |request|
    request.ip if request.path == "/oauth/token"
  end

  # Throttle admin endpoints to prevent brute-force attacks
  # More restrictive than general API limits since admin access is sensitive
  throttle("admin/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/admin/")
  end

  # Throttle web session creation (login) to slow down brute-force/password-spraying.
  # NOTE: this is the Rails web session endpoint, not the OAuth token endpoint.
  # Configurable via ENV: RACK_ATTACK_SESSION_LIMIT (default: 10),
  # RACK_ATTACK_SESSION_PERIOD_SECONDS (default: 60).
  throttle("sessions/create",
    limit:  ENV.fetch("RACK_ATTACK_SESSION_LIMIT", 10).to_i,
    period: ENV.fetch("RACK_ATTACK_SESSION_PERIOD_SECONDS", 60).to_i.seconds
  ) do |request|
    request.ip if request.post? && request.path == "/sessions"
  end

  # Determine limits based on self-hosted mode
  self_hosted = Rails.application.config.app_mode.self_hosted?

  # Throttle API requests per access token
  throttle("api/requests", limit: self_hosted ? 10_000 : 100, period: 1.hour) do |request|
    if request.path.start_with?("/api/")
      # Extract access token from Authorization header
      auth_header = request.get_header("HTTP_AUTHORIZATION")
      if auth_header&.start_with?("Bearer ")
        token = auth_header.split(" ").last
        "api_token:#{Digest::SHA256.hexdigest(token)}"
      else
        # Fall back to IP-based limiting for unauthenticated requests
        "api_ip:#{request.ip}"
      end
    end
  end

  # More permissive throttling for API requests by IP (for development/testing)
  throttle("api/ip", limit: self_hosted ? 20_000 : 200, period: 1.hour) do |request|
    request.ip if request.path.start_with?("/api/")
  end

  # F-06: Per-user OTP rate limiting on API login (mirrors web MFA: 5 attempts / 5 min).
  # Without this, the mobile/API login endpoint accepted unlimited OTP attempts
  # while the web flow enforced a 5-attempt / 5-minute lockout. Throttling by
  # normalized email means attackers can't trivially rotate IPs to bypass it.
  # Configurable via ENV: RACK_ATTACK_OTP_LIMIT (default: 5),
  # RACK_ATTACK_OTP_PERIOD_SECONDS (default: 300).
  # Helper for extracting a field from either form params or a JSON body
  # without consuming the body for downstream middleware. Mobile clients POST
  # JSON to /api/v1/auth/login, and Rack::Attack runs before Rails parses the
  # JSON body into request.params — so we parse it ourselves and rewind.
  module LoginRequestFields
    def self.read(request, field)
      value = request.params[field]
      return value if value.is_a?(String) && value.present?

      content_type = request.get_header("CONTENT_TYPE").to_s
      return nil unless content_type.include?("json")

      body = request.body.read
      request.body.rewind
      return nil if body.blank?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed[field] : nil
    rescue JSON::ParserError
      nil
    end
  end

  throttle("api/otp_attempts/email",
    limit:  ENV.fetch("RACK_ATTACK_OTP_LIMIT", 5).to_i,
    period: ENV.fetch("RACK_ATTACK_OTP_PERIOD_SECONDS", 300).to_i.seconds
  ) do |request|
    if request.path == "/api/v1/auth/login" && request.post?
      email    = LoginRequestFields.read(request, "email")
      otp_code = LoginRequestFields.read(request, "otp_code")
      email.to_s.downcase.strip if email.is_a?(String) && otp_code.is_a?(String) && otp_code.present?
    end
  end

  # Block requests that appear to be malicious
  blocklist("block malicious requests") do |request|
    # Block requests with suspicious user agents
    suspicious_user_agents = [
      /sqlmap/i,
      /nmap/i,
      /nikto/i,
      /masscan/i
    ]

    user_agent = request.user_agent
    suspicious_user_agents.any? { |pattern| user_agent =~ pattern } if user_agent
  end

  # Configure response for throttled requests
  self.throttled_responder = lambda do |request|
    [
      429, # status
      {
        "Content-Type" => "application/json",
        "Retry-After" => "60"
      },
      [ { error: "Rate limit exceeded. Try again later." }.to_json ]
    ]
  end

  # Configure response for blocked requests
  self.blocklisted_responder = lambda do |request|
    [
      403, # status
      { "Content-Type" => "application/json" },
      [ { error: "Request blocked." }.to_json ]
    ]
  end
end
