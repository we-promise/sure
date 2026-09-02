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

  # --- Credential-guessing surfaces (security audit #1087, finding H4) ---
  # Every endpoint in the app that checks a password, TOTP code, or backup
  # code against a stored value (enumerated by grepping for
  # User.authenticate_by/#authenticate/#verify_otp? across app/controllers —
  # #verify_otp? covers both TOTP and backup codes internally, so there's no
  # separate backup-code endpoint to add). Each is throttled by BOTH ip and
  # a credential-identifying discriminator (email, or the MFA step-up's
  # session-bound user id) so an attacker can't bypass by rotating IPs
  # against one target, nor by spraying many emails from one IP — either
  # throttle firing blocks the request, since Rack::Attack requires ALL
  # matching throttles to pass.
  #
  # oidc_account/create_link and api/v1/auth/sso_link are password checks
  # gating account linking, not sign-in — easy to miss by grepping routes.rb
  # for "session"/"login"/"password" alone.
  # request.params only exposes query/form parameters — Rack::Attack runs
  # ahead of Rails' JSON parameter parsing, so JSON API clients (the
  # documented format for api/v1/auth/login and .../sso_link) would otherwise
  # bypass the email throttle entirely. Peek at the JSON body without
  # consuming it, so the controller still gets a fresh, unread input stream.
  json_request_email = ->(request) do
    # Rack 3 no longer requires rack.input to be rewindable — bail out
    # without reading if the server's input stream can't be rewound, rather
    # than consuming a body the controller can never get back.
    next nil unless request.media_type == "application/json" && request.body.respond_to?(:rewind)

    body = request.body.read
    request.body.rewind
    payload = JSON.parse(body)
    payload["email"] if payload.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end

  credential_guess_email = ->(request) {
    email = request.params["email"].presence || json_request_email.call(request)
    email.to_s.downcase.strip.presence
  }

  # None of the routes below are declared `format: false`, so Rails' default
  # `(.:format)` segment means e.g. "/sessions.json" still reaches
  # SessionsController#create even though request.path for that request is
  # "/sessions.json". Exact string equality would silently skip every
  # throttle in this section for a scripted attacker who appends any
  # extension, while User.authenticate_by (etc.) still runs unthrottled.
  # Match the optional format suffix explicitly instead.
  credential_guess_path = ->(request, path) { request.path.match?(/\A#{Regexp.escape(path)}(?:\.[^.\/?]+)?\z/) }

  throttle("logins/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/sessions")
  end

  throttle("logins/email", limit: 10, period: 1.minute) do |request|
    credential_guess_email.call(request) if request.post? && credential_guess_path.call(request, "/sessions")
  end

  # MFA step-up has no email param — the pending user is looked up from
  # session[:mfa_user_id], so that's the discriminator instead.
  throttle("mfa/verify/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/mfa/verify")
  end

  throttle("mfa/verify/user", limit: 10, period: 1.minute) do |request|
    if request.post? && credential_guess_path.call(request, "/mfa/verify")
      request.session[:mfa_user_id]
    end
  end

  throttle("password_resets/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/password_reset")
  end

  throttle("password_resets/email", limit: 10, period: 1.minute) do |request|
    credential_guess_email.call(request) if request.post? && credential_guess_path.call(request, "/password_reset")
  end

  throttle("oidc_account_link/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/oidc_account/create_link")
  end

  throttle("oidc_account_link/email", limit: 10, period: 1.minute) do |request|
    credential_guess_email.call(request) if request.post? && credential_guess_path.call(request, "/oidc_account/create_link")
  end

  throttle("api_login/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/api/v1/auth/login")
  end

  throttle("api_login/email", limit: 10, period: 1.minute) do |request|
    credential_guess_email.call(request) if request.post? && credential_guess_path.call(request, "/api/v1/auth/login")
  end

  throttle("api_sso_link/ip", limit: 10, period: 1.minute) do |request|
    request.ip if request.post? && credential_guess_path.call(request, "/api/v1/auth/sso_link")
  end

  throttle("api_sso_link/email", limit: 10, period: 1.minute) do |request|
    credential_guess_email.call(request) if request.post? && credential_guess_path.call(request, "/api/v1/auth/sso_link")
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
