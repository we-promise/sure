require "json"
require "time"
require "uri"

class Provider::Scalable < Provider
  AUTH_HOST = "secure.scalable.capital".freeze
  GRAPHQL_HOST = "de.scalable.capital".freeze
  AUTH_ISSUER = "https://secure.scalable.capital".freeze
  AUDIENCE = "https://de.scalable.capital/api-gateway".freeze
  CLIENT_ID = "yBM3BrpRgwSTJZRdJllvtD6jJEmyxWfE".freeze
  GRAPHQL_URL = "https://de.scalable.capital/api/cli/graphql".freeze
  DEVICE_CODE_URL = "https://secure.scalable.capital/oauth/device/code".freeze
  TOKEN_URL = "https://secure.scalable.capital/oauth/token".freeze
  AUTH_SCOPE = "offline_access openid email".freeze
  DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code".freeze
  MAX_DEVICE_TTL_SECONDS = 20 * 60
  DEFAULT_POLL_INTERVAL_SECONDS = 5
  MIN_POLL_INTERVAL_SECONDS = 5
  MAX_POLL_INTERVAL_SECONDS = 60
  MFA_POLL_INTERVAL_SECONDS = 2
  MFA_TIMEOUT_SECONDS = 120
  TOKEN_REFRESH_SKEW_SECONDS = 60
  MAX_TOKEN_BYTES = 64 * 1024

  class Error < Provider::Error
    CODE_ALIASES = {
      "access_denied" => "authentication_failed",
      "credential_persistence_failed" => "provider_unavailable",
      "device_login_expired" => "challenge_expired",
      "invalid_credentials" => "authentication_failed",
      "invalid_operation" => "invalid_response",
      "invalid_request" => "invalid_response",
      "redirect_rejected" => "invalid_response",
      "request_timeout" => "provider_unavailable",
      "response_too_large" => "invalid_response",
      "token_invalid" => "authentication_failed",
      "two_factor_failed" => "authentication_failed",
      "unsafe_endpoint" => "invalid_response"
    }.freeze

    SAFE_MESSAGES = {
      "account_conflict" => "Scalable Capital account mapping conflicts with saved account data.",
      "account_identity_changed" => "Scalable Capital account identity changed. Reconnect to continue.",
      "authentication_failed" => "Scalable Capital authentication failed. Reconnect to continue.",
      "challenge_expired" => "Scalable Capital login approval expired. Start again.",
      "challenge_not_available" => "Scalable Capital login approval is unavailable. Start again.",
      "encryption_unavailable" => "Scalable Capital credentials cannot be stored securely on this installation.",
      "invalid_response" => "Scalable Capital returned an unexpected response.",
      "incomplete_snapshot" => "Scalable Capital returned incomplete account data. Saved account data was kept.",
      "login_authorization_changed" => "The Scalable Capital connection owner changed. Start again.",
      "login_in_progress" => "A Scalable Capital login is already in progress.",
      "provider_unavailable" => "Scalable Capital is unavailable. Try again later.",
      "rate_limited" => "Scalable Capital is temporarily rate limiting requests. Try again later.",
      "stale_snapshot" => "Scalable Capital account data changed during import. Saved account data was kept.",
      "session_expired" => "Scalable Capital session expired. Reconnect to continue.",
      "sync_failed" => "Scalable Capital data could not be synchronized. Saved account data was kept.",
      "unsupported_account" => "Scalable Capital returned an unsupported account.",
      "invalid_snapshot" => "Scalable Capital returned invalid account data. Saved account data was kept."
    }.freeze

    attr_reader :code

    def initialize(code)
      safe_code = code.to_s
      safe_code = CODE_ALIASES.fetch(safe_code, safe_code)
      safe_code = "sync_failed" unless SAFE_MESSAGES.key?(safe_code)
      @code = safe_code.freeze
      super(SAFE_MESSAGES.fetch(@code), details: nil, failure_code: @code)
    end

    def inspect
      "#<#{self.class.name}: #{code}>"
    end
    alias to_s inspect

    def as_json(*)
      { message: message, code: code }
    end
  end

  LoginResult = Data.define(:state, :pending_state, :credentials)

  def initialize(credentials: nil, on_credentials_update: nil)
    @credentials = normalize_hash(credentials)
    @on_credentials_update = on_credentials_update
  end

  def start_login
    key_pem = generate_dpop_key_pem
    response = post_form(
      DEVICE_CODE_URL,
      {
        "client_id" => CLIENT_ID,
        "audience" => AUDIENCE,
        "scope" => AUTH_SCOPE
      },
      key_pem: key_pem,
      allowed_hosts: [ AUTH_HOST ]
    )
    raise_oauth_error!(response, login: true) unless (200..299).cover?(response.status)

    payload = json_response!(response)
    device_code = bounded_string!(payload["device_code"], MAX_TOKEN_BYTES)
    user_code = bounded_string!(payload["user_code"], 128)
    complete_url = payload["verification_uri_complete"]
    base_url = payload["verification_uri"]
    verification_url = bounded_string!(complete_url.presence || base_url, 2_048)
    validate_verification_url!(verification_url)
    expires_in = payload["expires_in"]
    raise Error.new(:invalid_response) unless expires_in.is_a?(Integer) && expires_in.positive?
    interval = payload["interval"]
    raise Error.new(:invalid_response) if interval && !interval.is_a?(Integer)

    now = Time.now.utc
    ttl = [ expires_in, MAX_DEVICE_TTL_SECONDS ].min
    poll_interval = (interval || DEFAULT_POLL_INTERVAL_SECONDS).clamp(
      MIN_POLL_INTERVAL_SECONDS,
      MAX_POLL_INTERVAL_SECONDS
    )
    {
      "phase" => "device",
      "verification_url" => verification_url,
      "user_code" => user_code,
      "device_code" => device_code,
      "expires_at" => (now + ttl).iso8601,
      "poll_interval" => poll_interval,
      "next_poll_at" => (now + poll_interval).iso8601,
      "private_key_pem" => key_pem,
      "dpop_jkt" => dpop_thumbprint(key_pem),
      "pending_polls" => 0
    }
  rescue Error
    raise
  rescue StandardError
    raise Error.new(:invalid_response), cause: nil
  end

  def poll_login(pending_hash)
    pending = normalize_hash(pending_hash)
    key_pem = pending["private_key_pem"].to_s
    ensure_pending_key!(pending, key_pem)

    case pending["phase"]
    when "device"
      poll_device_login(pending, key_pem)
    when "phone_approval"
      poll_phone_approval(pending, key_pem)
    else
      raise Error.new(:invalid_request)
    end
  end

  def credentials
    duplicate_hash(@credentials)
  end

  def person_identity
    value = @credentials["person_id"]
    value if value.is_a?(String) && !value.strip.empty?
  end

  def refresh_if_needed!
    ensure_stored_credentials!
    expires_at = parse_time(@credentials["expires_at"])
    raise Error.new(:session_expired) unless expires_at
    return credentials if expires_at > Time.now.utc + TOKEN_REFRESH_SKEW_SECONDS

    refresh_credentials!
    credentials
  end

  def read(operation, variables: {})
    document = read_document!(operation)
    raise Error.new(:invalid_request) unless variables.is_a?(Hash)

    refresh_if_needed!
    used_access_token = @credentials.fetch("access_token")
    begin
      graphql_read!(document, variables, used_access_token)
    rescue Error => error
      raise unless error.code == "authentication_failed"

      refresh_credentials!(rejected_access_token: used_access_token)
      graphql_read!(document, variables, @credentials.fetch("access_token"))
    end
  end

  private

    def poll_device_login(pending, key_pem)
      assert_pending_deadline!(pending, "expires_at")
      return pending_result(pending) unless poll_due?(pending)

      response = post_form(
        TOKEN_URL,
        {
          "grant_type" => DEVICE_CODE_GRANT,
          "device_code" => bounded_string!(pending["device_code"], MAX_TOKEN_BYTES),
          "client_id" => CLIENT_ID
        },
        key_pem: key_pem,
        allowed_hosts: [ AUTH_HOST ]
      )

      unless (200..299).cover?(response.status)
        code = oauth_error_code(response)
        case code
        when "authorization_pending"
          pending["pending_polls"] = pending.fetch("pending_polls", 0).to_i + 1
          schedule_next_poll!(pending, pending.fetch("poll_interval", MIN_POLL_INTERVAL_SECONDS).to_i)
          return pending_result(pending)
        when "slow_down"
          pending["poll_interval"] = (pending.fetch("poll_interval", DEFAULT_POLL_INTERVAL_SECONDS).to_i + 2)
            .clamp(MIN_POLL_INTERVAL_SECONDS, MAX_POLL_INTERVAL_SECONDS)
          schedule_next_poll!(pending, pending["poll_interval"])
          return pending_result(pending)
        when "access_denied"
          raise Error.new(:access_denied)
        when "expired_token"
          raise Error.new(:device_login_expired)
        else
          raise_oauth_error!(response, login: true)
        end
      end

      token_payload = json_response!(response)
      token_credentials = credentials_from_token_payload!(token_payload, key_pem)
      finish_or_start_phone_approval(pending, token_credentials)
    end

    def finish_or_start_phone_approval(pending, token_credentials)
      state = auth_graphql!(
        query: <<~GRAPHQL,
          query Is2faOnLoginEnabled($input: Is2faOnLoginEnabledInput!) {
            is2faOnLoginEnabled(input: $input) {
              enabled
              hasApprovedSession
            }
          }
        GRAPHQL
        operation_name: "Is2faOnLoginEnabled",
        variables: { "input" => { "userId" => token_credentials.fetch("person_id") } },
        credentials: token_credentials
      ).dig("is2faOnLoginEnabled")
      raise Error.new(:two_factor_failed) unless state.is_a?(Hash) && [ true, false ].include?(state["enabled"])
      return authenticated_result(token_credentials) unless state["enabled"]
      raise Error.new(:two_factor_failed) unless [ true, false ].include?(state["hasApprovedSession"])
      return authenticated_result(token_credentials) if state["hasApprovedSession"]

      started = auth_graphql!(
        query: <<~GRAPHQL,
          mutation Start2faOnLogin($input: Start2faOnLoginInput!) {
            start2faOnLogin(input: $input) {
              mfaSessionId
            }
          }
        GRAPHQL
        operation_name: "Start2faOnLogin",
        variables: {
          "input" => {
            "userId" => token_credentials.fetch("person_id"),
            "deviceName" => "CLI",
            "deviceType" => "CLI"
          }
        },
        credentials: token_credentials
      ).dig("start2faOnLogin")
      mfa_session_id = started.is_a?(Hash) && started["mfaSessionId"]
      raise Error.new(:two_factor_failed) unless mfa_session_id.is_a?(String) && !mfa_session_id.strip.empty?

      pending["phase"] = "phone_approval"
      pending["pending_credentials"] = token_credentials
      pending["mfa_session_id"] = mfa_session_id
      pending["mfa_deadline"] = (Time.now.utc + MFA_TIMEOUT_SECONDS).iso8601
      pending["next_poll_at"] = Time.now.utc.iso8601
      poll_phone_approval(pending, token_credentials.fetch("private_key_pem"))
    rescue Error
      raise Error.new(:two_factor_failed), cause: nil
    end

    def poll_phone_approval(pending, key_pem)
      assert_pending_deadline!(pending, "mfa_deadline")
      assert_pending_deadline!(pending, "expires_at", optional: true)
      return pending_result(pending) unless poll_due?(pending)

      token_credentials = normalize_hash(pending["pending_credentials"])
      ensure_pending_key!(token_credentials, key_pem)
      status_data = auth_graphql!(
        query: <<~GRAPHQL,
          mutation Validate2faOnLogin($input: Validate2faOnLoginInput!) {
            validate2faOnLogin(input: $input) {
              status
            }
          }
        GRAPHQL
        operation_name: "Validate2faOnLogin",
        variables: {
          "input" => {
            "userId" => token_credentials.fetch("person_id"),
            "mfaSessionId" => bounded_string!(pending["mfa_session_id"], 256)
          }
        },
        credentials: token_credentials
      ).dig("validate2faOnLogin")
      status = status_data.is_a?(Hash) && status_data["status"]
      case status
      when "SUCCESS"
        authenticated_result(token_credentials)
      when "PENDING"
        schedule_next_poll!(pending, MFA_POLL_INTERVAL_SECONDS, minimum: MFA_POLL_INTERVAL_SECONDS)
        pending_result(pending)
      when "DENY", "TIMEOUT_RETRY"
        raise Error.new(:two_factor_failed)
      else
        raise Error.new(:two_factor_failed)
      end
    rescue Error => error
      raise error if error.code == "two_factor_failed"

      raise Error.new(:two_factor_failed), cause: nil
    end

    def auth_graphql!(query:, operation_name:, variables:, credentials:)
      response = post_json_with_dpop(
        GRAPHQL_URL,
        {
          "query" => query,
          "variables" => variables,
          "operation_name" => operation_name
        },
        key_pem: credentials.fetch("private_key_pem"),
        access_token: credentials.fetch("access_token"),
        allowed_hosts: [ GRAPHQL_HOST ]
      )
      reject_redirect!(response)
      unless (200..299).cover?(response.status)
        raise Error.new(:two_factor_failed)
      end

      parsed = JSON.parse(response.body)
      raise Error.new(:two_factor_failed) unless parsed.is_a?(Hash)
      raise Error.new(:two_factor_failed) if parsed["errors"].present?
      raise Error.new(:two_factor_failed) unless parsed["data"].is_a?(Hash)

      parsed.fetch("data")
    rescue Error
      raise Error.new(:two_factor_failed), cause: nil
    rescue JSON::ParserError, KeyError
      raise Error.new(:two_factor_failed), cause: nil
    end

    def credentials_from_token_payload!(payload, key_pem)
      access_token = bounded_string!(payload["access_token"], MAX_TOKEN_BYTES)
      claims = verify_access_token!(access_token, private_key_pem: key_pem)
      refresh_token = bounded_string!(payload["refresh_token"], MAX_TOKEN_BYTES)
      id_token = payload["id_token"]
      if id_token && (!id_token.is_a?(String) || id_token.bytesize > MAX_TOKEN_BYTES)
        raise Error.new(:invalid_response)
      end
      expires_in = payload["expires_in"]
      if expires_in && (!expires_in.is_a?(Integer) || expires_in <= 0)
        raise Error.new(:invalid_response)
      end

      now = Time.now.utc
      expiry_values = [ Time.at(claims.fetch("exp")).utc ]
      expiry_values << now + expires_in if expires_in
      {
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "id_token" => id_token,
        "expires_at" => expiry_values.min.iso8601,
        "person_id" => claims.fetch("person_id"),
        "session_id" => claims["session_id"],
        "private_key_pem" => key_pem,
        "dpop_jkt" => dpop_thumbprint(key_pem)
      }
    end

    def refresh_credentials!(rejected_access_token: nil)
      ensure_stored_credentials!
      current_access_token = @credentials.fetch("access_token")
      if rejected_access_token && current_access_token != rejected_access_token
        return credentials
      end

      refresh_token = @credentials["refresh_token"]
      raise Error.new(:session_expired) unless refresh_token.is_a?(String) && !refresh_token.strip.empty?

      old_claims = verify_access_token!(
        current_access_token,
        private_key_pem: @credentials.fetch("private_key_pem"),
        allow_expired: true
      )
      old_person_id = @credentials.fetch("person_id")
      raise Error.new(:session_expired) unless old_claims["person_id"] == old_person_id

      values = {
        "grant_type" => "refresh_token",
        "client_id" => CLIENT_ID,
        "refresh_token" => refresh_token
      }
      values["session_id"] = old_claims["session_id"] if old_claims["session_id"].present?
      response = post_form(
        TOKEN_URL,
        values,
        key_pem: @credentials.fetch("private_key_pem"),
        allowed_hosts: [ AUTH_HOST ]
      )
      raise_oauth_error!(response, login: false) unless (200..299).cover?(response.status)

      replacement = credentials_from_token_payload!(
        json_response!(response),
        @credentials.fetch("private_key_pem")
      )
      raise Error.new(:session_expired) unless replacement["refresh_token"].present?
      unless replacement["person_id"] == old_person_id &&
          replacement["dpop_jkt"] == dpop_thumbprint(@credentials.fetch("private_key_pem"))
        raise Error.new(:account_identity_changed)
      end
      persist_credentials!(replacement)
      replacement
    rescue Error => error
      if %w[authentication_failed invalid_response].include?(error.code)
        raise Error.new(:session_expired), cause: nil
      end

      raise
    rescue StandardError
      raise Error.new(:session_expired), cause: nil
    end

    def persist_credentials!(replacement)
      @on_credentials_update&.call(duplicate_hash(replacement))
      @credentials = duplicate_hash(replacement)
    rescue StandardError
      raise Error.new(:credential_persistence_failed), cause: nil
    end

    def graphql_read!(document, variables, access_token)
      response = post_json_with_dpop(
        GRAPHQL_URL,
        {
          "query" => document.fetch("query"),
          "variables" => variables,
          "operation_name" => document.fetch("name")
        },
        key_pem: @credentials.fetch("private_key_pem"),
        access_token: access_token,
        allowed_hosts: [ GRAPHQL_HOST ]
      )
      reject_redirect!(response)
      unless (200..299).cover?(response.status)
        raise Error.new(:authentication_failed) if response.status == 401
        raise Error.new(:rate_limited) if response.status == 429

        raise Error.new(:provider_unavailable)
      end

      parsed = JSON.parse(response.body)
      raise Error.new(:invalid_response) unless parsed.is_a?(Hash)
      if parsed["errors"].present?
        raise Error.new(:authentication_failed) if graphql_auth_error?(parsed["errors"])

        raise Error.new(:invalid_response)
      end
      raise Error.new(:invalid_response) unless parsed["data"].is_a?(Hash)

      parsed.fetch("data")
    rescue Error
      raise
    rescue JSON::ParserError, KeyError
      raise Error.new(:invalid_response), cause: nil
    end

    def read_document!(operation)
      key = case operation
      when Symbol then operation
      when String then operation.to_sym
      else raise Error.new(:invalid_operation)
      end
      documents = Provider::Scalable::ReadQueries::DOCUMENTS
      document = documents[key]
      raise Error.new(:invalid_operation) unless document.is_a?(Hash)

      name = document[:name] || document["name"]
      query = document[:query] || document["query"]
      raise Error.new(:invalid_operation) unless name.is_a?(String) && query.is_a?(String)
      raise Error.new(:invalid_operation) unless query.match?(/\A\s*query(?:\s|\()/)
      raise Error.new(:invalid_operation) if query.match?(/\b(?:mutation|subscription)\b/i)

      parsed_name = query.match(/\A\s*query\s+([_A-Za-z][_0-9A-Za-z]*)/)&.[](1)
      raise Error.new(:invalid_operation) unless parsed_name == name

      { "name" => name, "query" => query }
    rescue NameError
      raise Error.new(:invalid_operation), cause: nil
    end

    def graphql_auth_error?(errors)
      serialized = JSON.generate(errors)
      serialized.include?("UNAUTHENTICATED") || serialized.include?("Missing or invalid credentials")
    end

    def raise_oauth_error!(response, login:)
      raise Error.new(:rate_limited) if response.status == 429
      raise Error.new(:provider_unavailable) if response.status >= 500

      code = oauth_error_code(response)
      case code
      when "expired_token"
        raise Error.new(:device_login_expired)
      when "access_denied"
        raise Error.new(:access_denied)
      when "invalid_grant"
        raise Error.new(login ? :authentication_failed : :session_expired)
      else
        raise Error.new(login ? :authentication_failed : :session_expired)
      end
    end

    def oauth_error_code(response)
      parsed = JSON.parse(response.body)
      parsed.is_a?(Hash) ? parsed["error"].to_s : ""
    rescue JSON::ParserError
      ""
    end

    def validate_verification_url!(url)
      uri = validate_https_uri!(url, allowed_hosts: [ AUTH_HOST ])
      raise Error.new(:unsafe_endpoint) unless uri.path.start_with?("/")
      true
    end

    def ensure_pending_key!(state, key_pem)
      raise Error.new(:invalid_credentials) if key_pem.empty? || key_pem.bytesize > 16 * 1024

      thumbprint = dpop_thumbprint(key_pem)
      stored = state["dpop_jkt"]
      raise Error.new(:invalid_credentials) if stored.present? && stored != thumbprint
      true
    end

    def ensure_stored_credentials!
      required = %w[access_token person_id private_key_pem]
      raise Error.new(:session_expired) unless required.all? { |key| @credentials[key].is_a?(String) && !@credentials[key].strip.empty? }
      raise Error.new(:session_expired) if @credentials["access_token"].bytesize > MAX_TOKEN_BYTES

      ensure_pending_key!(@credentials, @credentials.fetch("private_key_pem"))
      stored_thumbprint = @credentials["dpop_jkt"]
      if stored_thumbprint.present? && stored_thumbprint != dpop_thumbprint(@credentials.fetch("private_key_pem"))
        raise Error.new(:session_expired)
      end
    end

    def assert_pending_deadline!(state, key, optional: false)
      value = state[key]
      return if optional && value.blank?

      deadline = parse_time(value)
      raise Error.new(:device_login_expired) unless deadline && Time.now.utc < deadline
    end

    def poll_due?(state)
      next_poll = parse_time(state["next_poll_at"])
      next_poll.nil? || Time.now.utc >= next_poll
    end

    def schedule_next_poll!(state, interval, minimum: MIN_POLL_INTERVAL_SECONDS)
      interval = interval.to_i.clamp(minimum, MAX_POLL_INTERVAL_SECONDS)
      state["poll_interval"] = interval
      state["next_poll_at"] = (Time.now.utc + interval).iso8601
    end

    def pending_result(state)
      LoginResult.new(state: :pending, pending_state: duplicate_hash(state), credentials: nil)
    end

    def authenticated_result(credentials)
      LoginResult.new(state: :authenticated, pending_state: nil, credentials: duplicate_hash(credentials))
    end

    def parse_time(value)
      return unless value.is_a?(String)

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def bounded_string!(value, max_bytes)
      raise Error.new(:invalid_response) unless value.is_a?(String) && !value.strip.empty? && value.bytesize <= max_bytes

      value
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end

    def duplicate_hash(value)
      normalize_hash(value).transform_values { |item| item.is_a?(String) ? item.dup : item }
    end
end

require_relative "scalable/transport"
require_relative "scalable/dpop"
require_relative "scalable/token_verifier"

class Provider::Scalable
  include Transport
  include Dpop
  include TokenVerifier
end
