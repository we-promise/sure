require "base64"
require "json"
require "net/http"
require "openssl"
require "timeout"

class Provider::CaAutoBank
  ORIGIN = "https://www.clienti.ca-autobank.it".freeze
  AUTH_ROOT = "/mybank-service/authentication/api/v1".freeze
  DEPOSIT_ROOT = "/mybank-service/term-deposit/api/v1/deposit-accounts".freeze
  BODY_LIMIT = 2.megabytes
  MAX_REPORTS = 20
  MAX_DEPOSITS = 200

  class Error < StandardError
    attr_reader :code, :diagnostics

    def initialize(code, diagnostics: {})
      @code = code.to_s
      @diagnostics = diagnostics.slice(:operation, :http_status, :bank_error_code, :transport_error).freeze
      super(@code)
    end
  end

  AuthResult = Data.define(:authentication_token, :verification_token) do
    def authenticated?
      authentication_token.present?
    end

    def inspect
      "#<Provider::CaAutoBank::AuthResult: #{authenticated? ? 'authenticated' : 'pending'}>"
    end
  end

  Snapshot = Data.define(:identity, :generation, :observed_at, :reports) do
    def inspect
      "#<Provider::CaAutoBank::Snapshot>"
    end
  end

  attr_reader :request_session_id

  def initialize(authentication_token: nil, request_session_id: SecureRandom.alphanumeric(26))
    @authentication_token = authentication_token
    @request_session_id = request_session_id
  end

  def begin_login(email:, password:)
    status, body = request(:post, "#{AUTH_ROOT}/login", body: {
      email: email, password: password, loginRequestingPlatform: "CUSTOMER_PORTAL"
    }, authentication: false, allow_pending: true)
    login_result(status, body)
  end

  def poll_login(verification_token:)
    status, body = request(:post, "#{AUTH_ROOT}/login/tfa",
      body: { verificationToken: verification_token }, authentication: false, allow_pending: true)
    login_result(status, body, verification_token: verification_token)
  end

  def account_identity
    body = get("#{AUTH_ROOT}/user")
    value = body["partnerId"]
    raise Error.new(:invalid_session, diagnostics: @last_response_diagnostics) unless value.is_a?(String) && value.present? && value.bytesize <= 256

    value
  end

  def fetch_snapshot(identity:, generation:)
    raise Error.new(:account_identity_changed) unless account_identity == identity

    observed_at = Time.current
    reports = array!(get(DEPOSIT_ROOT), "depositAccountReports", MAX_REPORTS)
    contracts = array!(get("#{DEPOSIT_ROOT}/contracts"), "depositAccountContracts", MAX_REPORTS)
    raise Error.new(:incomplete_snapshot) if reports.empty? || reports.size != contracts.size

    bundles = reports.map do |raw_report|
      report = report_scope(raw_report)
      matches = contracts.select { |contract| contract.is_a?(Hash) && contract["accountNumber"] == report["accountNumber"] }
      raise Error.new(:incomplete_snapshot) unless matches.one?

      contract = matches.sole
      overview = post("#{DEPOSIT_ROOT}/overview", report: report.merge("accountHolderName" => contract.fetch("accountHolderName")))
      processed = post("#{DEPOSIT_ROOT}/time-deposits/processed",
        report: report, startDate: "2015-01-01", endDate: observed_at.in_time_zone("Europe/Rome").to_date.iso8601, status: "ACTIVE")
      deposits = array!(processed, "processedTimeDeposits", MAX_DEPOSITS).map do |deposit|
        raise Error.new(:invalid_snapshot) unless deposit.is_a?(Hash)

        details = post("#{DEPOSIT_ROOT}/time-deposits/details",
          report: report, operationNumber: deposit.fetch("operationNumber"), timeDepositToken: deposit.fetch("timeDepositToken"))
        { "summary" => deposit, "details" => details }
      end
      { "report" => report, "contract" => contract, "overview" => overview, "deposits" => deposits }
    end

    Snapshot.new(identity: identity, generation: generation, observed_at: observed_at, reports: bundles)
  rescue KeyError, TypeError
    raise Error.new(:invalid_snapshot), cause: nil
  end

  def self.token_expires_at(token)
    raise Error.new(:invalid_session) unless token.is_a?(String) && token.bytesize.between?(64, 16_384)

    parts = token.split(".", -1)
    raise Error.new(:invalid_session) unless parts.size == 3 && parts.all? { |part| /\A[A-Za-z0-9_-]+\z/.match?(part) }

    header = JSON.parse(Base64.urlsafe_decode64(parts.first))
    claims = JSON.parse(Base64.urlsafe_decode64(parts.second))
    raise Error.new(:invalid_session) unless header.is_a?(Hash) && header["alg"] == "ES512" && claims.is_a?(Hash)

    expiry = claims["exp"]
    raise Error.new(:invalid_session) unless expiry.is_a?(Integer) && expiry.positive?

    Time.at(expiry).utc
  rescue JSON::ParserError, ArgumentError, RangeError, TypeError
    raise Error.new(:invalid_session), cause: nil
  end

  private

    def get(path)
      request(:get, path).last
    end

    def post(path, body)
      request(:post, path, body: body).last
    end

    def report_scope(raw)
      raise Error.new(:invalid_snapshot) unless raw.is_a?(Hash)

      %w[service branch accountNumber].to_h do |key|
        value = raw.fetch(key)
        raise Error.new(:invalid_snapshot) unless value.is_a?(Integer) && value >= 0

        [ key, value ]
      end
    end

    def array!(body, key, limit)
      value = body[key]
      raise Error.new(:incomplete_snapshot) unless value.is_a?(Array) && value.size <= limit

      value
    end

    def login_result(status, body, verification_token: nil)
      if status == 200
        token = body["authenticationToken"]
        raise Error.new(:unsupported_login) unless token.is_a?(String) && token.present?

        self.class.token_expires_at(token)
        AuthResult.new(authentication_token: token, verification_token: nil)
      elsif status == 511 && body["appAuthorizationRequired"] == true && [ 5110000, 5110003 ].include?(body["errorCode"])
        token = body["verificationToken"] || verification_token
        raise Error.new(:invalid_session) unless token.is_a?(String) && token.bytesize.between?(1, 16_384)

        AuthResult.new(authentication_token: nil, verification_token: token)
      else
        raise Error.new(:unsupported_login)
      end
    end

    def request(method, path, body: nil, authentication: true, allow_pending: false)
      uri = URI.join(ORIGIN, path)
      headers = {
        "Accept" => "application/json", "Content-Type" => "application/json",
        "X-Application-Id" => "0", "X-Device-Id" => "0", "X-Brand" => "MY_BANK",
        "X-Session-Id" => request_session_id, "X-Trace-Id" => SecureRandom.uuid
      }
      if authentication
        raise Error.new(:session_expired) if @authentication_token.blank?

        headers["Authorization"] = "Bearer #{@authentication_token}"
      end
      http_request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
      http_request.body = JSON.generate(body) if body
      status = nil
      response_body = +""
      Timeout.timeout(25) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15, write_timeout: 10) do |http|
          http.max_retries = 0
          http.request(http_request) do |response|
            status = response.code.to_i
            response.read_body do |chunk|
              raise Error.new(:invalid_response) if response_body.bytesize + chunk.bytesize > BODY_LIMIT

              response_body << chunk
            end
          end
        end
      end
      @last_response_diagnostics = response_diagnostics(path, status, response_body)
      raise Error.new(:session_expired) if authentication && [ 401, 403 ].include?(status)
      raise Error.new(:authentication_failed) if !authentication && [ 400, 401, 403 ].include?(status)
      raise Error.new(:rate_limited) if status == 429
      raise Error.new(:provider_unavailable) unless status == 200 || (allow_pending && status == 511)

      parsed = JSON.parse(response_body)
      raise Error.new(:invalid_response) unless parsed.is_a?(Hash)

      [ status, parsed ]
    rescue Error => error
      raise Error.new(error.code, diagnostics: response_diagnostics(path, status, response_body)), cause: nil
    rescue JSON::ParserError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      raise Error.new(:invalid_response, diagnostics: response_diagnostics(path, status, response_body)), cause: nil
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, SocketError => error
      details = response_diagnostics(path, status, response_body).merge(transport_error: error.class.name)
      raise Error.new(:provider_unavailable, diagnostics: details), cause: nil
    end

    def response_diagnostics(path, status, response_body)
      operation = {
        "#{AUTH_ROOT}/login" => "login_start", "#{AUTH_ROOT}/login/tfa" => "approval_check",
        "#{AUTH_ROOT}/user" => "identity_verification", DEPOSIT_ROOT => "deposit_accounts",
        "#{DEPOSIT_ROOT}/contracts" => "deposit_contracts", "#{DEPOSIT_ROOT}/overview" => "deposit_overview",
        "#{DEPOSIT_ROOT}/time-deposits/processed" => "active_deposits", "#{DEPOSIT_ROOT}/time-deposits/details" => "deposit_details"
      }.fetch(path, "unknown")
      details = { operation: operation, http_status: status }.compact
      parsed = JSON.parse(response_body.to_s)
      code = parsed["errorCode"] if parsed.is_a?(Hash)
      details[:bank_error_code] = code if code.is_a?(Integer) && code.between?(0, 999_999_999)
      details
    rescue JSON::ParserError
      details
    end
end
