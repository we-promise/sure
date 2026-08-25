# frozen_string_literal: true

class Rack::Attack
  # Enable Rack::Attack only in production and staging (disable in test/development to avoid rate-limit flakiness)
  enabled = Rails.env.production? || Rails.env.staging?
  self.enabled = enabled

  # Throttle requests to the OAuth token endpoint
  throttle("oauth/token", limit: 10, period: 1.minute) do |request|
    request.ip if request.path == "/oauth/token"
  end

  throttle("oauth/register", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && request.path == "/register"
  end

  # Throttle unauthenticated WebAuthn ceremonies similarly to sign-in
  # endpoints; registration remains behind normal application authentication.
  # Covers both the MFA step-up and passwordless passkey sign-in.
  throttle("mfa/webauthn", limit: 10, period: 1.minute) do |request|
    if request.post? && request.path.in?(%w[
         /mfa/webauthn_options
         /mfa/verify_webauthn
         /sessions/passkey
       ])
      request.ip
    end
  end

  # The passwordless challenge endpoint gets its own, looser budget: browsers
  # that support conditional mediation call it automatically on every login
  # page load, so sharing the limit above would let ordinary page views lock a
  # shared NAT out of MFA. Minting a challenge touches no credential and
  # reveals nothing, and the assertion it produces is still verified under the
  # stricter limit.
  throttle("passkey/options", limit: 30, period: 1.minute) do |request|
    request.ip if request.post? && request.path == "/sessions/passkey_options"
  end

  # Throttle admin endpoints to prevent brute-force attacks
  # More restrictive than general API limits since admin access is sensitive
  throttle("admin/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/admin/")
  end

  # The background jobs console lives under /settings (so its polling GET
  # isn't throttled), but its mutation is destructive and super-admin only —
  # rate limit it independently.
  throttle("background_jobs_console/ip", limit: 30, period: 1.minute) do |request|
    request.ip if request.post? && request.path == "/settings/background_jobs/cancel"
  end

  # Determine limits based on self-hosted mode
  self_hosted = Rails.application.config.app_mode.self_hosted?

  # Throttle API requests per access token
  throttle("api/requests", limit: self_hosted ? 10_000 : 100, period: 1.hour) do |request|
    if request.path.start_with?("/api/")
      # Extract access token from Authorization header
      auth_header = request.get_header("HTTP_AUTHORIZATION")
      if auth_header&.start_with?("Bearer ")
        token = auth_header.delete_prefix("Bearer ").strip # pipelock:ignore
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
