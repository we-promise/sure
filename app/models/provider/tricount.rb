# frozen_string_literal: true

# Client for Tricount's private HTTP API, the one its mobile apps use. Tricount
# (a bunq product) publishes no API: this follows the protocol documented by the
# open-source clients that reverse-engineered the Android app, and it may change
# without notice.
#
# There is no login. The client registers an anonymous device (an installation
# UUID and an RSA public key) and gets a session token and a user id back. A
# tricount's sharing token, the part after tricount.com/ in its link, gives that
# device access to the tricount once it is synchronised to the device. Sure only
# reads: it never creates, edits or deletes anything in a tricount.
class Provider::Tricount
  include HTTParty

  base_uri "https://api.tricount.bunq.com"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 60)

  # The API answers only clients that present themselves as the Android app,
  # and Tricount enforces a minimum app version: an older version string is
  # refused with a 422 asking to update the app. TRICOUNT_APP_USER_AGENT
  # overrides it, so the next required bump needs no code change.
  DEFAULT_USER_AGENT = "com.bunq.tricount.android:RELEASE:14.1.0:5400:ANDROID:14:C"
  OUTDATED_CLIENT_MESSAGE = /update your app/i
  # Tricount only enforces a minimum version, so when it refuses the version
  # above, a request is retried once claiming this far-ahead one and the client
  # keeps working until DEFAULT_USER_AGENT is bumped. It is a recovery path
  # only: a version ahead of the real app could one day get responses shaped
  # for app features this client does not handle.
  # TRICOUNT_FALLBACK_APP_USER_AGENT overrides it.
  FALLBACK_USER_AGENT = "com.bunq.tricount.android:RELEASE:99.0.0:9999:ANDROID:14:C"
  # A fallback that worked is remembered for a day, so later syncs skip the
  # refused attempt, and the normal version is tried again afterwards.
  FALLBACK_CACHE_KEY = "provider/tricount/app_user_agent_fallback"
  FALLBACK_TTL = 1.day
  # A sharing token as it appears in a tricount link: tricount.com/tAbC123...
  SHARING_TOKEN_FORMAT = /\At[A-Za-z0-9]{4,64}\z/

  def self.user_agent
    ENV["TRICOUNT_APP_USER_AGENT"].presence || DEFAULT_USER_AGENT
  end

  def self.fallback_user_agent
    ENV["TRICOUNT_FALLBACK_APP_USER_AGENT"].presence || FALLBACK_USER_AGENT
  end

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  Session = Data.define(:token, :user_id)

  # A new anonymous device: an installation UUID and an RSA public key in PKCS#1
  # PEM. The private key is not kept: the API never asks for a signature.
  def self.generate_device
    key = OpenSSL::PKey::RSA.new(2048)
    der = OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(key.n), OpenSSL::ASN1::Integer(key.e) ]).to_der
    pem = "-----BEGIN RSA PUBLIC KEY-----\n#{Base64.strict_encode64(der).scan(/.{1,64}/).join("\n")}\n-----END RSA PUBLIC KEY-----\n"

    { app_installation_uuid: SecureRandom.uuid, client_public_key: pem }
  end

  # The sharing token in a tricount link or a bare token, or nil.
  def self.sharing_token_from(input)
    candidate = input.to_s.strip
    return nil if candidate.empty?

    candidate = URI.parse(candidate).path.to_s.split("/").reject(&:empty?).last.to_s if candidate.include?("/")
    candidate.match?(SHARING_TOKEN_FORMAT) ? candidate : nil
  rescue URI::InvalidURIError
    nil
  end

  attr_reader :app_installation_uuid, :client_public_key, :session_token, :user_id

  # on_session: called with the Session whenever the client registers, so the
  # caller can keep the token and user id for the next sync.
  def initialize(app_installation_uuid:, client_public_key:, session_token: nil, user_id: nil, on_session: nil)
    raise ConfigurationError, "Installation UUID is required" if app_installation_uuid.blank?
    raise ConfigurationError, "Client public key is required" if client_public_key.blank?

    @app_installation_uuid = app_installation_uuid
    @client_public_key = client_public_key
    @session_token = session_token
    @user_id = user_id
    @on_session = on_session
  end

  # Registers the device and returns its Session.
  def register!
    response = with_retries("register") do
      self.class.post(
        "/v1/session-registry-installation",
        headers: base_headers,
        body: {
          app_installation_uuid: app_installation_uuid,
          client_public_key: client_public_key,
          device_description: "Android"
        }.to_json
      )
    end

    objects = response_objects(handle_response(response))
    token = objects.find { |object| object.key?("Token") }&.dig("Token", "token")
    user_id = objects.find { |object| object.key?("UserPerson") }&.dig("UserPerson", "id")
    raise AuthenticationError.new("Tricount did not return a session", :unauthorized) if token.blank? || user_id.blank?

    @session_token = token
    @user_id = user_id.to_s
    session = Session.new(token: @session_token, user_id: @user_id)
    @on_session&.call(session)
    session
  end

  # Gives the device access to the tricounts behind these sharing tokens.
  def synchronize!(sharing_tokens)
    tokens = Array(sharing_tokens).compact_blank.uniq
    return if tokens.empty?

    authenticated("synchronize") do
      self.class.post(
        "/v1/user/#{user_id}/registry-synchronization",
        headers: session_headers,
        body: {
          all_registry_active: tokens.map { |token| { public_identifier_token: token } },
          all_registry_archived: [],
          all_registry_deleted: []
        }.to_json
      )
    end
  end

  # The tricount behind a sharing token, with its memberships and entries, or nil.
  def registry(sharing_token)
    payload = authenticated("registry") do
      self.class.get(
        "/v1/user/#{user_id}/registry",
        headers: session_headers,
        query: { public_identifier_token: sharing_token }
      )
    end

    response_objects(payload).filter_map { |object| object["Registry"] }.first
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    # Runs a request with the session, registering first when there is none and
    # once more when the session has expired.
    def authenticated(operation_name)
      register! if session_token.blank? || user_id.blank?
      reregistered = false

      begin
        handle_response(with_retries(operation_name) { yield })
      rescue AuthenticationError
        raise if reregistered

        reregistered = true
        register!
        retry
      end
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        with_app_version_fallback(operation_name) { yield }
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error) if retries > max_retries

        delay = [ INITIAL_RETRY_DELAY * (2**(retries - 1)), 30 ].min
        Rails.logger.warn("Tricount API: #{operation_name} failed (attempt #{retries}/#{max_retries}): #{e.class}. Retrying in #{delay}s...")
        sleep(delay)
        retry
      end
    end

    # Sends a request, and when Tricount refuses the app version as outdated,
    # sends it once more claiming the fallback version (see FALLBACK_USER_AGENT).
    def with_app_version_fallback(operation_name)
      response = yield
      return response unless outdated_client?(response) && current_user_agent != self.class.fallback_user_agent

      @current_user_agent = self.class.fallback_user_agent
      retried = yield
      unless outdated_client?(retried)
        remember_fallback!
        warn_fallback_in_use(operation_name)
      end
      retried
    end

    def outdated_client?(response)
      response.respond_to?(:code) && response.code == 422 && response.body.to_s.match?(OUTDATED_CLIENT_MESSAGE)
    end

    def current_user_agent
      @current_user_agent ||= fallback_remembered? ? self.class.fallback_user_agent : self.class.user_agent
    end

    def fallback_remembered?
      Rails.cache.read(FALLBACK_CACHE_KEY).present?
    rescue StandardError
      false
    end

    def remember_fallback!
      Rails.cache.write(FALLBACK_CACHE_KEY, true, expires_in: FALLBACK_TTL)
    rescue StandardError
      nil
    end

    def warn_fallback_in_use(operation_name)
      message = "Tricount refused app version #{self.class.user_agent.split(":")[2]} as outdated; " \
                "using the fallback version. Bump Provider::Tricount::DEFAULT_USER_AGENT or set TRICOUNT_APP_USER_AGENT."
      Rails.logger.warn("Tricount API: #{message}")
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "tricount",
        metadata: { operation: operation_name }
      )
    rescue StandardError
      nil
    end

    def base_headers
      {
        "User-Agent" => current_user_agent,
        "app-id" => app_installation_uuid,
        # bunq expects a request id that is unique per request.
        "X-Bunq-Client-Request-Id" => SecureRandom.uuid,
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def session_headers
      base_headers.merge("X-Bunq-Client-Authentication" => session_token)
    end

    def response_objects(payload)
      Array(payload.is_a?(Hash) ? payload["Response"] : nil).select { |object| object.is_a?(Hash) }
    end

    # Bodies are not logged: they hold the tricount's members and expenses.
    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body.presence || "{}")
      when 400
        raise Error.new("Tricount rejected the request (400)", :bad_request)
      when 401, 403
        raise AuthenticationError.new("Tricount refused the session (#{response.code})", :unauthorized)
      when 404
        raise Error.new("Tricount not found", :not_found)
      when 422
        if response.body.to_s.match?(OUTDATED_CLIENT_MESSAGE)
          raise Error.new("Tricount requires a newer app version; set TRICOUNT_APP_USER_AGENT or update Sure", :client_outdated)
        end
        raise Error.new("Unexpected Tricount response (422)", :unknown)
      when 429
        raise Error.new("Tricount rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Tricount server error (#{response.code}). Please try again later.", :server_error)
      else
        raise Error.new("Unexpected Tricount response (#{response.code})", :unknown)
      end
    rescue JSON::ParserError
      raise Error.new("Tricount returned an unreadable response", :invalid_response)
    end
end
