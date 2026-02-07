# frozen_string_literal: true

class Provider::IndexaCapital
  include HTTParty

  headers "User-Agent" => "Sure Finance IndexaCapital Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  BASE_URL = "https://api.indexacapital.com"

  attr_reader :username, :document, :password

  def initialize(username:, document:, password:)
    @username = username
    @document = document
    @password = password
    validate_configuration!
  end

  # TODO: Implement provider-specific API methods
  # Example methods for investment providers:

  # def list_accounts
  #   with_retries("list_accounts") do
  #     response = self.class.get(
  #       "#{base_url}/accounts",
  #       headers: auth_headers
  #     )
  #     handle_response(response)
  #   end
  # end

  # def get_holdings(account_id:)
  #   with_retries("get_holdings") do
  #     response = self.class.get(
  #       "#{base_url}/accounts/#{account_id}/holdings",
  #       headers: auth_headers
  #     )
  #     handle_response(response)
  #   end
  # end

  # def get_activities(account_id:, start_date:, end_date: Date.current)
  #   with_retries("get_activities") do
  #     response = self.class.get(
  #       "#{base_url}/accounts/#{account_id}/activities",
  #       headers: auth_headers,
  #       query: { start_date: start_date.to_s, end_date: end_date.to_s }
  #     )
  #     handle_response(response)
  #   end
  # end

  # def delete_connection(authorization_id:)
  #   with_retries("delete_connection") do
  #     response = self.class.delete(
  #       "#{base_url}/authorizations/#{authorization_id}",
  #       headers: auth_headers
  #     )
  #     handle_response(response)
  #   end
  # end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "Username is required" if @username.blank?
      raise ConfigurationError, "Document is required" if @document.blank?
      raise ConfigurationError, "Password is required" if @password.blank?
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "IndexaCapital API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "IndexaCapital API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def base_url
      BASE_URL
    end

    def base_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def auth_headers
      base_headers.merge("Authorization" => "Bearer #{token}")
    end

    def token
      @token ||= authenticate!
    end

    def authenticate!
      response = self.class.post(
        "#{base_url}/auth/authenticate",
        headers: base_headers,
        body: {
          username: username,
          document: document,
          password: password
        }.to_json
      )
      payload = handle_response(response)
      token = payload[:token]
      raise AuthenticationError.new("Authentication token missing in response", :unauthorized) if token.blank?

      token
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "IndexaCapital API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("IndexaCapital server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "IndexaCapital API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end
end
