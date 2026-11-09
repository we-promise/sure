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

  # The API answers only clients that present themselves as the Android app.
  USER_AGENT = "com.bunq.tricount.android:RELEASE:7.0.7:3174:ANDROID:13:C"
  # A sharing token as it appears in a tricount link: tricount.com/tAbC123...
  SHARING_TOKEN_FORMAT = /\At[A-Za-z0-9]{4,64}\z/

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
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1
        raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error) if retries > max_retries

        delay = [ INITIAL_RETRY_DELAY * (2**(retries - 1)), 30 ].min
        Rails.logger.warn("Tricount API: #{operation_name} failed (attempt #{retries}/#{max_retries}): #{e.class}. Retrying in #{delay}s...")
        sleep(delay)
        retry
      end
    end

    def base_headers
      {
        "User-Agent" => USER_AGENT,
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
