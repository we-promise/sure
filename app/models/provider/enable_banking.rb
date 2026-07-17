require "cgi"

class Provider::EnableBanking
  include HTTParty
  extend SslConfigurable

  BASE_URL = "https://api.enablebanking.com".freeze

  headers "User-Agent" => "Sure Finance Enable Banking Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :application_id, :private_key

  def initialize(application_id:, client_certificate:)
    @application_id = application_id
    @private_key = extract_private_key(client_certificate)
  end

  # Get list of available ASPSPs (banks) for a country
  # @param country [String] ISO 3166-1 alpha-2 country code (e.g., "GB", "DE", "FR")
  # @return [Array<Hash>] List of ASPSPs
  def get_aspsps(country:)
    response = self.class.get(
      "#{BASE_URL}/aspsps",
      headers: auth_headers,
      query: { country: country }
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Initiate authorization flow - returns a redirect URL for the user
  # @param aspsp_name [String] Name of the ASPSP from get_aspsps
  # @param aspsp_country [String] Country code for the ASPSP
  # @param redirect_url [String] URL to redirect user back to after auth
  # @param state [String, nil] State parameter to pass through
  # @param psu_type [String] "personal" or "business"
  # @param maximum_consent_validity [Integer, nil] Max consent duration in seconds from ASPSP (nil = use 90 days)
  # @param language [String, nil] Two-letter language code (e.g. "fr", "en")
  # @param auth_method [String, nil] Name of a specific authentication method to use (from the ASPSP's
  #   auth_methods list). Required to drive DECOUPLED/EMBEDDED banks that expose several methods; when nil
  #   Enable Banking falls back to the ASPSP's default method.
  # @return [Hash] Contains :url and :authorization_id
  def start_authorization(aspsp_name:, aspsp_country:, redirect_url:, state: nil,
                          psu_type: "personal", maximum_consent_validity: nil, language: nil, auth_method: nil)
    max_seconds = maximum_consent_validity ? [ maximum_consent_validity, 1 ].max : 90.days.to_i
    valid_until = [ Time.current + max_seconds.seconds, Time.current + 90.days ].min

    body = {
      access: {
        valid_until: valid_until.iso8601,
        balances: true,
        transactions: true
      },
      aspsp: {
        name: aspsp_name,
        country: aspsp_country
      },
      state: state,
      redirect_url: redirect_url,
      psu_type: psu_type
    }
    body[:language] = language if language.present?
    body[:auth_method] = auth_method if auth_method.present?
    body = body.compact

    response = self.class.post(
      "#{BASE_URL}/auth",
      headers: auth_headers.merge("Content-Type" => "application/json"),
      body: body.to_json
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during POST request: #{e.message}", :request_failed)
  end

  # Exchange authorization code for a session
  # @param code [String] The authorization code from the callback
  # @return [Hash] Contains :session_id and :accounts
  def create_session(code:)
    body = {
      code: code
    }

    response = self.class.post(
      "#{BASE_URL}/sessions",
      headers: auth_headers.merge("Content-Type" => "application/json"),
      body: body.to_json
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during POST request: #{e.message}", :request_failed)
  end

  # Get session information
  # @param session_id [String] The session ID
  # @return [Hash] Session info including accounts
  def get_session(session_id:)
    response = self.class.get(
      "#{BASE_URL}/sessions/#{session_id}",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Delete a session (revoke consent)
  # @param session_id [String] The session ID
  def delete_session(session_id:)
    response = self.class.delete(
      "#{BASE_URL}/sessions/#{session_id}",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during DELETE request: #{e.message}", :request_failed)
  end

  # Get account details
  # @param account_id [String] The account ID (UID from Enable Banking)
  # @param psu_headers [Hash] Optional PSU context headers required by some ASPSPs
  # @return [Hash] Account details
  def get_account_details(account_id:, psu_headers: {})
    encoded_id = CGI.escape(account_id.to_s)
    response = self.class.get(
      "#{BASE_URL}/accounts/#{encoded_id}/details",
      headers: auth_headers.merge(safe_psu_headers(psu_headers))
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get account balances
  # @param account_id [String] The account ID (UID from Enable Banking)
  # @param psu_headers [Hash] Optional PSU context headers required by some ASPSPs
  # @return [Hash] Balance information
  def get_account_balances(account_id:, psu_headers: {})
    encoded_id = CGI.escape(account_id.to_s)
    response = self.class.get(
      "#{BASE_URL}/accounts/#{encoded_id}/balances",
      headers: auth_headers.merge(safe_psu_headers(psu_headers))
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get account transactions
  # @param account_id [String] The account ID (UID from Enable Banking)
  # @param date_from [Date, nil] Start date for transactions
  # @param date_to [Date, nil] End date for transactions
  # @param continuation_key [String, nil] For pagination
  # @param transaction_status [String, nil] Filter: "BOOK", "PDNG", or nil for all
  # @param psu_headers [Hash] Optional PSU context headers required by some ASPSPs
  # @return [Hash] Transactions and continuation_key for pagination
  def get_account_transactions(account_id:, date_from: nil, date_to: nil,
                               continuation_key: nil, transaction_status: nil, psu_headers: {}, retried_date_from: false)
    encoded_id = CGI.escape(account_id.to_s)
    query_params = {}
    query_params[:transaction_status] = transaction_status if transaction_status.present?
    query_params[:date_from] = date_from.to_date.iso8601 if date_from
    query_params[:date_to] = date_to.to_date.iso8601 if date_to
    query_params[:continuation_key] = continuation_key if continuation_key

    response = self.class.get(
      "#{BASE_URL}/accounts/#{encoded_id}/transactions",
      headers: auth_headers.merge(safe_psu_headers(psu_headers)),
      query: query_params.presence
    )

    handle_response(response)
  rescue EnableBankingError => e
    corrected_date_from = e.corrected_date_from

    if !retried_date_from && e.wrong_transactions_period? && corrected_date_from.present? && corrected_date_from != date_from
      get_account_transactions(
        account_id: account_id,
        date_from: corrected_date_from,
        date_to: date_to,
        continuation_key: continuation_key,
        transaction_status: transaction_status,
        psu_headers: psu_headers,
        retried_date_from: true
      )
    else
      raise
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise EnableBankingError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  private

    def safe_psu_headers(headers)
      headers.except("Authorization", :Authorization, "Accept", :Accept, "Content-Type", :"Content-Type")
    end

    def extract_private_key(certificate_pem)
      # Extract private key from PEM certificate
      OpenSSL::PKey::RSA.new(certificate_pem)
    rescue OpenSSL::PKey::RSAError => e
      Rails.logger.error "Enable Banking: Failed to parse private key: #{e.message}"
      raise EnableBankingError.new("Invalid private key in certificate: #{e.message}", :invalid_certificate)
    end

    def generate_jwt
      now = Time.current.to_i

      header = {
        typ: "JWT",
        alg: "RS256",
        kid: application_id
      }

      payload = {
        iss: "enablebanking.com",
        aud: "api.enablebanking.com",
        iat: now,
        exp: now + 3600  # 1 hour expiry
      }

      # Encode JWT
      JWT.encode(payload, private_key, "RS256", header)
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{generate_jwt}",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      response_data = parse_error_response_body(response.body)

      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        raise mapped_error(response, response_data, default_type: :bad_request, default_message: "Bad request to Enable Banking API")
      when 401
        raise mapped_error(response, response_data, default_type: :unauthorized, default_message: "Invalid credentials or expired JWT")
      when 403
        raise mapped_error(response, response_data, default_type: :access_forbidden, default_message: "Access forbidden - check your application permissions")
      when 404
        raise mapped_error(response, response_data, default_type: :not_found, default_message: "Resource not found")
      when 408
        raise mapped_error(response, response_data, default_type: :timeout, default_message: "Request timeout from Enable Banking API")
      when 422
        raise mapped_error(response, response_data, default_type: :validation_error, default_message: "Validation error from Enable Banking API")
      when 429
        raise mapped_error(response, response_data, default_type: :rate_limited, default_message: "Rate limit exceeded. Please try again later.")
      else
        raise mapped_error(response, response_data, default_type: :fetch_failed, default_message: "Failed to fetch data")
      end
    end

    def parse_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "Enable Banking API: Failed to parse response: #{e.message}"
      raise EnableBankingError.new("Failed to parse API response", :parse_error)
    end

    def parse_error_response_body(body)
      return nil if body.blank?

      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    def mapped_error(response, response_data, default_type:, default_message:)
      error_code = response_data.is_a?(Hash) ? response_data[:error].presence : nil

      error_type = case error_code
      when "ASPSP_ERROR" then :aspsp_error
      when "ASPSP_TIMEOUT" then :timeout
      when "ASPSP_RATE_LIMIT_EXCEEDED" then :rate_limited
      when "WRONG_TRANSACTIONS_PERIOD" then :validation_error
      when "EXPIRED_SESSION" then :unauthorized
      else default_type
      end

      suffix = response.body.present? ? ": #{response.body}" : nil
      EnableBankingError.new("#{default_message}#{suffix}", error_type, response_data: response_data)
    end

    class EnableBankingError < StandardError
      attr_reader :error_type, :response_data

      def initialize(message, error_type = :unknown, response_data: nil)
        super(message)
        @error_type = error_type
        @response_data = response_data
      end

      def wrong_transactions_period?
        error_type == :validation_error && response_data.is_a?(Hash) && response_data[:error] == "WRONG_TRANSACTIONS_PERIOD"
      end

      def aspsp_error?
        error_type == :aspsp_error
      end

      def corrected_date_from
        value = response_data&.dig(:detail, :date_from)

        if value.is_a?(Date)
          value
        elsif value.present?
          Date.iso8601(value)
        end
      rescue ArgumentError
        nil
      end
    end
end
