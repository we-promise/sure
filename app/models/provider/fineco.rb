# frozen_string_literal: true

require "bigdecimal"
require "date"
require "digest"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "set"
require "timeout"
require "time"
require "uri"

class Provider::Fineco
  ACCOUNT_LIST_ENDPOINT = URI("https://private-api.finecobank.com/v1/private/users/accounts").freeze
  ENDPOINT = URI("https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi").freeze
  MOVEMENTS_ENDPOINT = URI("https://private-api.finecobank.com/v1/private/dossier-order/movements").freeze
  HOST = "private-api.finecobank.com".freeze
  PORTFOLIO_REFERER = "https://finecobank.com/pvt/portfolio/trading-summary/home".freeze
  MOVEMENTS_REFERER = "https://finecobank.com/pvt/portfolio/report/accounts/movements".freeze

  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 10
  WRITE_TIMEOUT_SECONDS = 5
  TOTAL_TIMEOUT_SECONDS = 30
  MAX_BODY_BYTES = 2 * 1024 * 1024
  MAX_POSITION_COUNT = 2_000
  MAX_MOVEMENTS_PER_PAGE = 10
  MAX_MOVEMENTS_PER_WINDOW = 1_000
  MAX_MOVEMENTS_OFFSET = 10_000
  BANK_TIME_ZONE = "Europe/Rome".freeze
  MOVEMENTS_DATE_MINIMUM = Date.new(2018, 1, 1).freeze
  MOVEMENTS_TYPES = %w[ORDER TITLE].freeze
  MOVEMENTS_ROW_REQUIRED_FIELDS = %w[
    type transactionDate valueDate description name isin sign amount currency price exchange equivalentValue
  ].freeze
  MOVEMENT_DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  MOVEMENT_SHORT_STRING_LIMIT = 64
  MAX_FILTER_VALUE_COUNT = 256
  MAX_SAFE_BUSINESS_NUMBER = (2**53) - 1
  IDENTITY_NAMESPACE = "fineco/business-account-dossier/v1".freeze

  COOKIE_VALUE_PATTERN = /\A[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]{1,512}\z/
  INDEX_PATTERN = /\A\d{1,6}\z/

  SUMMARY_REQUIRED_FIELDS = %w[
    currencyCd bookValue marketValue profitLoss profitLossPerc accrual
  ].freeze
  SUMMARY_MONEY_FIELDS = %w[bookValue marketValue profitLoss accrual].freeze
  POSITION_MONEY_FIELDS = %w[bookValue marketValue profitLoss].freeze
  POSITION_REQUIRED_FIELDS = %w[
    instrId venueSystem currencyCd qty marketPrice bookValue marketValue profitLoss
  ].freeze
  POSITION_MARKET_DATA_FIELDS = %w[marketPrice marketValue profitLoss].freeze
  POSITION_NON_MARKET_DATA_FIELDS = (POSITION_REQUIRED_FIELDS - POSITION_MARKET_DATA_FIELDS).freeze
  OPTIONAL_POSITION_NUMBER_FIELDS = %w[avgPrice accrual ongoingAccrual].freeze
  FILTER_GROUPS = %w[currencies instrumentTypes].freeze
  STEP_UP_MARKERS = %w[
    authorisationid availablemethods strong_auth strongauth step_up stepup
    sca_required scarequired
  ].freeze
  READ_STEP_UP_MARKER = "sca di sessione non valida".freeze

  STATIC_HEADERS = {
    "User-Agent" => "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Mobile Safari/537.36",
    "Accept-Language" => "it",
    "Cache-Control" => "no-cache",
    "Pragma" => "no-cache",
    "Connection" => "keep-alive",
    "Sec-Fetch-Dest" => "empty",
    "Sec-Fetch-Mode" => "cors",
    "Sec-Fetch-Site" => "same-site",
    "sec-ch-ua" => '"Google Chrome";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
    "sec-ch-ua-mobile" => "?1",
    "sec-ch-ua-platform" => '"Android"',
    "sec-gpc" => "1",
    "Origin" => "https://finecobank.com",
    "Content-Type" => "application/json",
    "Referer" => PORTFOLIO_REFERER,
    "Accept" => "application/json, text/plain, */*"
  }.freeze

  class Error < StandardError
    def inspect
      "#<#{self.class.name}: #{message}>"
    end
  end

  class ConfigurationError < Error; end
  class IdentityVerificationRequired < Error; end
  class ReauthenticationRequired < Error; end
  class RedirectRejected < Error; end
  class InvalidResponse < Error; end
  class MarketDataUnavailable < InvalidResponse; end
  class MovementsWindowTooLarge < Error; end

  class MovementsDateRangeUnavailable < Error
    attr_reader :earliest_date

    def initialize(earliest_date)
      @earliest_date = earliest_date
      super("Fineco movements are available from a later date.")
    end

    def inspect
      "#<#{self.class.name}: validated>"
    end
    alias to_s inspect
  end
  class ResponseTooLarge < Error; end
  class RequestTimeout < Error; end
  class RequestFailed < Error; end

  class UpstreamResponse < Error
    attr_reader :status

    def initialize(status)
      @status = status
      super("Fineco returned HTTP #{status}.")
    end
  end

  class PortfolioResult
    attr_reader :payload, :rotated_gsessionid, :account_number, :dossier_identity

    def initialize(payload:, rotated_gsessionid:, account_number:, dossier_identity:)
      @payload = payload
      @rotated_gsessionid = rotated_gsessionid
      @account_number = account_number
      @dossier_identity = dossier_identity
    end

    def inspect
      "#<#{self.class.name}: validated>"
    end
    alias to_s inspect
  end

  class MovementsPage
    attr_reader :payload, :rotated_gsessionid, :account_number, :dossier_identity

    def initialize(payload:, rotated_gsessionid:, account_number:, dossier_identity:)
      @payload = payload
      @rotated_gsessionid = rotated_gsessionid
      @account_number = account_number
      @dossier_identity = dossier_identity
    end

    def inspect
      "#<#{self.class.name}: validated>"
    end
    alias to_s inspect
  end

  class VerifiedBankIdentity
    def initialize(account_number:, dossier_identity:)
      @account_number = account_number
      @dossier_identity = dossier_identity
    end

    def matches?(account_number:, dossier_identity:)
      @account_number == account_number.to_s && @dossier_identity == dossier_identity.to_s
    end

    def inspect
      "#<#{self.class.name}: verified>"
    end
    alias to_s inspect
  end

  def initialize(gsessionid:, account_index:, dossier_index:)
    @gsessionid = validate_cookie!(gsessionid)
    @account_index = validate_index!(account_index)
    @dossier_index = validate_index!(dossier_index)
    @last_rotated_gsessionid = nil
  end

  def self.verified_identity_contract?
    true
  end

  def fetch_portfolio_summary
    @last_rotated_gsessionid = nil
    @last_verified_bank_identity = nil

    unless self.class.verified_identity_contract?
      raise IdentityVerificationRequired, "Fineco account identity verification is required."
    end

    ::Timeout.timeout(TOTAL_TIMEOUT_SECONDS, RequestTimeout, "Fineco request timed out.") do
      identity_response, identity_body = request_endpoint(ACCOUNT_LIST_ENDPOINT, @gsessionid)
      validate_success_response!(identity_response, identity_body)
      identity = selected_bank_identity!(parse_payload(identity_body))
      @last_verified_bank_identity = VerifiedBankIdentity.new(
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
      retain_rotated_gsessionid!(identity_response)

      payload = fetch_validated_portfolio!

      PortfolioResult.new(
        payload: payload,
        rotated_gsessionid: @last_rotated_gsessionid,
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
    end
  rescue ReauthenticationRequired, RedirectRejected, InvalidResponse, ResponseTooLarge,
         RequestTimeout, RequestFailed, ConfigurationError, UpstreamResponse
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error
    raise RequestTimeout.new("Fineco request timed out."), cause: nil
  rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, EOFError, IOError, Net::HTTPError
    raise RequestFailed.new("Fineco request failed."), cause: nil
  end

  def fetch_movements_page(date_from:, date_to:, offset:, movement_type: "ORDER")
    @last_rotated_gsessionid = nil
    @last_verified_bank_identity = nil

    unless self.class.verified_identity_contract?
      raise IdentityVerificationRequired, "Fineco account identity verification is required."
    end

    normalized_type = validate_movements_type!(movement_type)
    normalized_offset = validate_movements_offset!(offset)
    from_date, to_date = validate_movements_dates!(date_from, date_to)

    ::Timeout.timeout(TOTAL_TIMEOUT_SECONDS, RequestTimeout, "Fineco request timed out.") do
      identity_response, identity_body = request_endpoint(ACCOUNT_LIST_ENDPOINT, @gsessionid)
      validate_success_response!(identity_response, identity_body)
      identity = selected_bank_identity!(parse_payload(identity_body))
      @last_verified_bank_identity = VerifiedBankIdentity.new(
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
      retain_rotated_gsessionid!(identity_response)

      request_body = {
        "type" => normalized_type,
        "keyword" => {
          "key" => "ADVANCED",
          "word" => "",
          "dateFrom" => from_date.iso8601,
          "dateTo" => to_date.iso8601
        },
        "offset" => normalized_offset,
        "limit" => MAX_MOVEMENTS_PER_PAGE
      }
      movement_response, movement_body = request_endpoint(
        MOVEMENTS_ENDPOINT,
        @last_rotated_gsessionid.presence || @gsessionid,
        method: :post,
        body: request_body,
        headers: {
          "X-Subaccount-Index" => "01",
          "X-Request-Id" => SecureRandom.uuid,
          "Referer" => MOVEMENTS_REFERER
        }
      )
      validate_success_response!(movement_response, movement_body)
      payload = parse_movements_payload(movement_body)
      validate_movements_page!(payload, movement_type: normalized_type)
      retain_rotated_gsessionid!(movement_response)

      MovementsPage.new(
        payload: payload,
        rotated_gsessionid: @last_rotated_gsessionid,
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
    end
  rescue ReauthenticationRequired, RedirectRejected, InvalidResponse, ResponseTooLarge,
         RequestTimeout, RequestFailed, ConfigurationError, UpstreamResponse
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error
    raise RequestTimeout.new("Fineco request timed out."), cause: nil
  rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, EOFError, IOError, Net::HTTPError
    raise RequestFailed.new("Fineco request failed."), cause: nil
  end

  def fetch_movements_window(date_from:, date_to:, movement_type: "ORDER")
    @last_rotated_gsessionid = nil
    @last_verified_bank_identity = nil

    unless self.class.verified_identity_contract?
      raise IdentityVerificationRequired, "Fineco account identity verification is required."
    end

    normalized_type = validate_movements_type!(movement_type)
    from_date, to_date = validate_movements_dates!(date_from, date_to)

    ::Timeout.timeout(TOTAL_TIMEOUT_SECONDS, RequestTimeout, "Fineco request timed out.") do
      identity_response, identity_body = request_endpoint(ACCOUNT_LIST_ENDPOINT, @gsessionid)
      validate_success_response!(identity_response, identity_body)
      identity = selected_bank_identity!(parse_payload(identity_body))
      @last_verified_bank_identity = VerifiedBankIdentity.new(
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
      retain_rotated_gsessionid!(identity_response)

      request_body = {
        "type" => normalized_type,
        "keyword" => {
          "key" => "ADVANCED",
          "word" => "",
          "dateFrom" => from_date.iso8601,
          "dateTo" => to_date.iso8601
        },
        "offset" => 0,
        "limit" => -1
      }
      begin
        movement_response, movement_body = request_endpoint(
          MOVEMENTS_ENDPOINT,
          @last_rotated_gsessionid.presence || @gsessionid,
          method: :post,
          body: request_body,
          headers: {
            "X-Subaccount-Index" => "01",
            "X-Request-Id" => SecureRandom.uuid,
            "Referer" => MOVEMENTS_REFERER
          }
        )
      rescue ResponseTooLarge
        raise MovementsWindowTooLarge, "Fineco movements window exceeded the response size limit."
      end

      begin
        validate_movements_window_response!(movement_response, movement_body)
      rescue MovementsDateRangeUnavailable
        retain_rotated_gsessionid!(movement_response)
        raise
      end
      payload = parse_movements_payload(movement_body)
      begin
        validate_movements_window!(payload, movement_type: normalized_type)
      rescue MovementsWindowTooLarge
        retain_rotated_gsessionid!(movement_response)
        raise
      end
      retain_rotated_gsessionid!(movement_response)

      MovementsPage.new(
        payload: payload,
        rotated_gsessionid: @last_rotated_gsessionid,
        account_number: identity.fetch(:account_number),
        dossier_identity: identity.fetch(:dossier_identity)
      )
    end
  rescue ReauthenticationRequired, RedirectRejected, InvalidResponse, MovementsWindowTooLarge,
         MovementsDateRangeUnavailable,
         ResponseTooLarge, RequestTimeout, RequestFailed, ConfigurationError, UpstreamResponse
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error
    raise RequestTimeout.new("Fineco request timed out."), cause: nil
  rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, EOFError, IOError, Net::HTTPError
    raise RequestFailed.new("Fineco request failed."), cause: nil
  end

  def inspect
    "#<#{self.class.name}: authenticated client>"
  end
  alias to_s inspect

  attr_reader :last_rotated_gsessionid
  attr_reader :last_verified_bank_identity

  private

    def request_endpoint(uri, gsessionid, method: :get, body: nil, headers: {})
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true if http.respond_to?(:verify_hostname=)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.write_timeout = WRITE_TIMEOUT_SECONDS
      http.max_retries = 0 if http.respond_to?(:max_retries=)

      request_class = case method
      when :get then Net::HTTP::Get
      when :post then Net::HTTP::Post
      else raise ConfigurationError, "Fineco request method is invalid."
      end
      request = request_class.new(uri.request_uri)
      STATIC_HEADERS.each { |key, value| request[key] = value }
      headers.each { |key, value| request[key] = value }
      request["X-Account-Index"] = @account_index
      request["X-Dossier-Index"] = @dossier_index
      request["Cookie"] = "gsessionid=#{gsessionid}"
      request.body = JSON.generate(body) if body

      response = nil
      body = +""
      http.start do |connection|
        response = connection.request(request) do |incoming|
          read_limited_body(incoming, body)
        end
      end

      [ response, body ]
    rescue RequestTimeout, ResponseTooLarge, InvalidResponse
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise RequestTimeout.new("Fineco request timed out."), cause: nil
    rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, EOFError, IOError, Net::HTTPError
      raise RequestFailed.new("Fineco request failed."), cause: nil
    end

    def validate_success_response!(response, body)
      status = response.code.to_i

      raise ReauthenticationRequired, "Fineco session requires reauthentication." if [ 401, 403 ].include?(status)
      raise RedirectRejected, "Fineco returned a redirect; the session was not forwarded." if status.between?(300, 399)
      raise_sca_or_upstream!(status, body) unless status == 200

      signal_reauthentication!(body)
    end

    def selected_bank_identity!(payload)
      accounts = payload["accounts"]
      unless accounts.is_a?(Array) && accounts.size <= MAX_POSITION_COUNT
        raise InvalidResponse, "Fineco returned an incomplete account selection response."
      end

      account_records = accounts.map do |account|
        raise InvalidResponse, "Fineco could not verify the selected account." unless account.is_a?(Hash)

        [ account, canonical_business_number!(account["number"]) ]
      end
      account_numbers = account_records.map(&:last)
      unless account_numbers.uniq.length == account_numbers.length
        raise InvalidResponse, "Fineco could not verify the selected account."
      end

      account_matches = account_records.select do |account, _number|
        selected_index?(account["index"], @account_index)
      end
      unless account_matches.one?
        raise InvalidResponse, "Fineco could not verify the selected account."
      end

      account, account_number = account_matches.first

      dossiers = account["dossiers"]
      unless dossiers.is_a?(Array) && dossiers.size <= MAX_POSITION_COUNT
        raise InvalidResponse, "Fineco returned an incomplete dossier selection response."
      end

      dossier_records = dossiers.map do |dossier|
        raise InvalidResponse, "Fineco could not verify the selected dossier." unless dossier.is_a?(Hash)

        [ dossier, canonical_business_number!(dossier["number"]) ]
      end
      dossier_numbers = dossier_records.map(&:last)
      unless dossier_numbers.uniq.length == dossier_numbers.length
        raise InvalidResponse, "Fineco could not verify the selected dossier."
      end

      dossier_matches = dossier_records.select do |dossier, _number|
        selected_index?(dossier["index"], @dossier_index)
      end
      unless dossier_matches.one?
        raise InvalidResponse, "Fineco could not verify the selected dossier."
      end

      _dossier, dossier_number = dossier_matches.first
      identity_pair = [ IDENTITY_NAMESPACE, account_number, dossier_number ]
      dossier_identity = Digest::SHA256.hexdigest(JSON.generate(identity_pair))
      { account_number: account_number, dossier_identity: dossier_identity }
    end

    def canonical_business_number!(value)
      unless value.is_a?(Integer) && value.positive? && value <= MAX_SAFE_BUSINESS_NUMBER
        raise InvalidResponse, "Fineco could not verify the selected business identity."
      end

      value.to_s
    end

    def selected_index?(value, expected)
      case value
      when Integer then value.to_s == expected
      when String then value.match?(INDEX_PATTERN) && value == expected
      else false
      end
    end

    def read_limited_body(response, body)
      content_length = response["content-length"]
      if content_length.present?
        unless content_length.match?(/\A\d+\z/)
          raise InvalidResponse, "Fineco returned an invalid response length."
        end
        raise ResponseTooLarge, "Fineco response exceeded the size limit." if content_length.to_i > MAX_BODY_BYTES
      end

      response.read_body do |chunk|
        if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
          raise ResponseTooLarge, "Fineco response exceeded the size limit."
        end

        body << chunk
      end
    end

    def raise_sca_or_upstream!(status, body)
      if status == 451 && body_signals_reauthentication?(body)
        raise ReauthenticationRequired, "Fineco session requires reauthentication."
      end

      raise UpstreamResponse, status
    end

    def signal_reauthentication!(body)
      raise ReauthenticationRequired, "Fineco session requires reauthentication." if body_signals_reauthentication?(body)
    end

    def body_signals_reauthentication?(body)
      lower_body = body.to_s.downcase
      lower_body.include?(READ_STEP_UP_MARKER) || STEP_UP_MARKERS.any? { |marker| lower_body.include?(marker) }
    end

    def parse_payload(body)
      payload = JSON.parse(body)
      raise InvalidResponse, "Fineco returned an invalid portfolio response." unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError, Encoding::InvalidByteSequenceError
      raise InvalidResponse.new("Fineco returned an invalid portfolio response."), cause: nil
    end

    def validate_movements_type!(movement_type)
      return movement_type if movement_type.is_a?(String) && MOVEMENTS_TYPES.include?(movement_type)

      raise ConfigurationError, "Fineco movements type is invalid."
    end

    def validate_movements_offset!(offset)
      unless offset.is_a?(Integer) && offset.between?(0, MAX_MOVEMENTS_OFFSET) && (offset % MAX_MOVEMENTS_PER_PAGE).zero?
        raise ConfigurationError, "Fineco movements offset is invalid."
      end

      offset
    end

    def validate_movements_dates!(date_from, date_to)
      from_date = movement_date!(date_from)
      to_date = movement_date!(date_to)
      today = Time.find_zone!(BANK_TIME_ZONE).today

      unless from_date >= MOVEMENTS_DATE_MINIMUM && to_date >= from_date && to_date <= today
        raise ConfigurationError, "Fineco movements date range is invalid."
      end

      [ from_date, to_date ]
    end

    def movement_date!(value)
      return value if value.instance_of?(Date)
      return Date.iso8601(value) if value.is_a?(String) && value.match?(MOVEMENT_DATE_PATTERN)

      raise ConfigurationError, "Fineco movements date is invalid."
    rescue ArgumentError
      raise ConfigurationError, "Fineco movements date is invalid."
    end

    def parse_movements_payload(body)
      payload = JSON.parse(body)
      raise InvalidResponse, "Fineco returned an invalid movements response." unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError, Encoding::InvalidByteSequenceError
      raise InvalidResponse.new("Fineco returned an invalid movements response."), cause: nil
    end

    def validate_movements_page!(payload, movement_type:)
      movements = payload["movements"]
      unless movements.is_a?(Array) && movements.size <= MAX_MOVEMENTS_PER_PAGE &&
             [ true, false ].include?(payload["lastPage"]) && [ true, false ].include?(payload["limitedResult"])
        raise InvalidResponse, "Fineco returned an incomplete movements page."
      end
      raise InvalidResponse, "Fineco limited the requested movements result." if payload["limitedResult"]

      movements.each do |movement|
        if movement_type == "ORDER"
          validate_order_movement!(movement)
        elsif !movement.is_a?(Hash)
          raise InvalidResponse, "Fineco returned an invalid movements row."
        end
      end
    end

    def validate_movements_window!(payload, movement_type:)
      movements = payload["movements"]
      unless movements.is_a?(Array) && [ true, false ].include?(payload["lastPage"]) &&
             [ true, false ].include?(payload["limitedResult"])
        raise InvalidResponse, "Fineco returned an incomplete movements window."
      end
      raise MovementsWindowTooLarge, "Fineco limited the requested movements window." if payload["limitedResult"]
      if movements.size >= MAX_MOVEMENTS_PER_WINDOW
        raise MovementsWindowTooLarge, "Fineco movements window reached the row limit."
      end

      movements.each do |movement|
        if movement_type == "ORDER"
          validate_order_movement!(movement)
        elsif !movement.is_a?(Hash)
          raise InvalidResponse, "Fineco returned an invalid movements row."
        end
      end
    end

    def validate_movements_window_response!(response, body)
      validate_success_response!(response, body)
    rescue UpstreamResponse => error
      raise unless error.status == 400

      earliest_date = movements_earliest_available_date(body)
      raise MovementsDateRangeUnavailable.new(earliest_date) if earliest_date

      raise
    end

    def movements_earliest_available_date(body)
      payload = JSON.parse(body)
      issues = payload["issues"] if payload.is_a?(Hash)
      return unless issues.is_a?(Array) && issues.one? && issues.first.is_a?(Hash)

      reason = issues.first["reason"]
      return unless reason.is_a?(String)

      match = /\ASono accettate solo date dal (?<day>\d{1,2}) (?<month>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (?<year>\d{4}) fino ad oggi\.\z/i.match(reason)
      return unless match

      month = {
        "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4,
        "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8,
        "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12
      }.fetch(match[:month].downcase)
      earliest_date = Date.new(match[:year].to_i, month, match[:day].to_i)
      bank_today = Time.find_zone!(BANK_TIME_ZONE).today
      earliest_date if earliest_date.between?(MOVEMENTS_DATE_MINIMUM, bank_today)
    rescue JSON::ParserError, ArgumentError, Encoding::InvalidByteSequenceError
      nil
    end

    def validate_order_movement!(movement)
      unless movement.is_a?(Hash) && MOVEMENTS_ROW_REQUIRED_FIELDS.all? { |field| movement.key?(field) }
        raise InvalidResponse, "Fineco returned an incomplete movements row."
      end

      unless bounded_movement_string?(movement["transactionDate"]) && bounded_movement_string?(movement["valueDate"]) &&
             bounded_movement_string?(movement["type"], max_bytes: MOVEMENT_SHORT_STRING_LIMIT) &&
             bounded_movement_string?(movement["sign"], max_bytes: MOVEMENT_SHORT_STRING_LIMIT) &&
             movement["description"].is_a?(String) && movement["name"].is_a?(String) &&
             movement["isin"].is_a?(String) && FinecoItem::PortfolioNormalizer.valid_isin?(movement["isin"]) &&
             movement["currency"].is_a?(String) && movement["currency"].present? &&
             movement["currency"].bytesize <= MOVEMENT_SHORT_STRING_LIMIT
        raise InvalidResponse, "Fineco returned an invalid movements row."
      end

      unless iso_datetime?(movement["transactionDate"]) && iso_datetime?(movement["valueDate"])
        raise InvalidResponse, "Fineco returned an invalid movements date."
      end

      unless %w[amount price exchange equivalentValue].all? { |field| finite_movement_number?(movement[field]) }
        raise InvalidResponse, "Fineco returned an invalid movements value."
      end
    end

    def bounded_movement_string?(value, max_bytes: 64)
      value.is_a?(String) && value.present? && value.bytesize <= max_bytes
    end

    def iso_datetime?(value)
      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    def finite_movement_number?(value)
      decimal = case value
      when BigDecimal, Integer, Float then BigDecimal(value.to_s)
      when String then BigDecimal(value)
      else return false
      end
      decimal.finite?
    rescue ArgumentError
      false
    end

    def validate_portfolio!(payload)
      info = payload["info"]
      dossier = info.is_a?(Hash) ? info["dossier"] : nil
      unless dossier.is_a?(Hash) && [ true, false ].include?(dossier["blocked"])
        raise InvalidResponse, "Fineco returned an incomplete portfolio response."
      end
      raise ReauthenticationRequired, "Fineco session requires reauthentication." if dossier["blocked"]

      positions_section = payload["positions"]
      positions = positions_section.is_a?(Hash) ? positions_section["show"] : nil
      unless positions.is_a?(Array) && positions.size <= MAX_POSITION_COUNT
        raise InvalidResponse, "Fineco returned an incomplete portfolio response."
      end

      summary = payload["summary"]
      unless summary.is_a?(Hash)
        raise InvalidResponse, "Fineco returned an incomplete portfolio response."
      end

      show = summary["show"]
      total = summary["total"]
      validate_filters!(payload["filters"])
      validate_summary!(show)
      validate_summary!(total)
      rows, market_data_unavailable = validate_positions!(positions)
      validate_summary_totals!(show, total, rows)
      if market_data_unavailable
        validate_quote_unavailable_context!(show, total, positions)
        raise MarketDataUnavailable, "Fineco temporarily omitted market data for a portfolio position."
      end
    end

    def validate_filters!(filters)
      unless filters.is_a?(Hash)
        raise InvalidResponse, "Fineco returned incomplete portfolio filters."
      end

      FILTER_GROUPS.each do |group_name|
        group = filters[group_name]
        unless group.is_a?(Hash) && group.key?("total") && group.key?("show")
          raise InvalidResponse, "Fineco returned incomplete portfolio filters."
        end

        total = filter_set_value!(group["total"])
        show = filter_set_value!(group["show"])
        unless total == show
          raise InvalidResponse, "Fineco returned filtered portfolio positions."
        end
      end
    end

    def filter_set_value!(value)
      unless value.is_a?(Array) && value.size <= MAX_FILTER_VALUE_COUNT &&
             value.all? { |entry| entry.is_a?(String) && entry.present? && entry.length <= 32 }
        raise InvalidResponse, "Fineco returned invalid portfolio filters."
      end

      entries = value.map(&:strip)
      unless entries.uniq.size == entries.size
        raise InvalidResponse, "Fineco returned invalid portfolio filters."
      end

      entries.sort
    end

    def validate_summary!(summary)
      unless summary.is_a?(Hash) && SUMMARY_REQUIRED_FIELDS.all? { |field| summary.key?(field) }
        raise InvalidResponse, "Fineco returned an incomplete portfolio summary."
      end
      unless summary["currencyCd"].is_a?(String) && summary["currencyCd"].match?(/\A[A-Za-z]{3}\z/)
        raise InvalidResponse, "Fineco returned an invalid portfolio currency."
      end

      (SUMMARY_MONEY_FIELDS + [ "profitLossPerc" ]).each do |field|
        decimal_value(summary[field])
      end
    end

    def validate_positions!(positions)
      market_data_unavailable = false
      rows = positions.map do |position|
        if missing_market_data_fields?(position)
          unless market_data_unavailable_position?(position)
            raise InvalidResponse, "Fineco returned an incomplete portfolio position."
          end

          market_data_unavailable = true
          {
            "bookValue" => decimal_value(position["bookValue"]),
            "accrual" => position["accrual"].nil? ? BigDecimal("0") : decimal_value(position["accrual"])
          }
        else
          validate_complete_position!(position)
        end
      end

      [ rows, market_data_unavailable ]
    end

    def validate_complete_position!(position)
      unless position.is_a?(Hash) && POSITION_REQUIRED_FIELDS.all? { |field| position.key?(field) } &&
             position["instrId"].is_a?(String) && position["instrId"].present? &&
             position["venueSystem"].is_a?(String) && position["venueSystem"].present? &&
             position["currencyCd"].is_a?(String) && position["currencyCd"].match?(/\A[A-Za-z]{3}\z/)
        raise InvalidResponse, "Fineco returned an incomplete portfolio position."
      end

      POSITION_MONEY_FIELDS.each { |field| decimal_value(position[field]) }
      decimal_value(position["qty"])
      decimal_value(position["marketPrice"])
      accrual = position["accrual"].nil? ? BigDecimal("0") : decimal_value(position["accrual"])
      {
        "bookValue" => decimal_value(position["bookValue"]),
        "marketValue" => decimal_value(position["marketValue"]),
        "profitLoss" => decimal_value(position["profitLoss"]),
        "accrual" => accrual
      }
    end

    def missing_market_data_fields?(position)
      position.is_a?(Hash) && POSITION_MARKET_DATA_FIELDS.none? { |field| position.key?(field) }
    end

    def validate_quote_unavailable_context!(show, total, positions)
      unless show["currencyCd"] == "EUR" && total["currencyCd"] == "EUR"
        raise InvalidResponse, "Fineco returned an invalid portfolio currency."
      end

      identities = positions.map do |position|
        unless valid_quote_unavailable_context_position?(position)
          raise InvalidResponse, "Fineco returned an unsupported portfolio position."
        end

        position["instrId"].upcase
      end

      unless identities.uniq.size == identities.size
        raise InvalidResponse, "Fineco returned duplicate portfolio positions."
      end
    end

    def valid_quote_unavailable_context_position?(position)
      return false unless position.is_a?(Hash)
      return false unless POSITION_NON_MARKET_DATA_FIELDS.all? { |field| position.key?(field) }
      return false unless position["instrId"].is_a?(String) && FinecoItem::PortfolioNormalizer.valid_isin?(position["instrId"])
      return false unless position["type"].is_a?(String) &&
        FinecoItem::PortfolioNormalizer::SUPPORTED_POSITION_TYPES.include?(position["type"].downcase)
      return false unless position["venueSystem"].is_a?(String)

      mic = FinecoItem::PortfolioNormalizer::MIC_MAP[position["venueSystem"].upcase]
      return false unless mic.present? && Security::EXCHANGES.key?(mic)
      return false unless position["currencyCd"].is_a?(String) && position["currencyCd"].match?(/\A[A-Za-z]{3}\z/)

      quote_fields_missing = POSITION_MARKET_DATA_FIELDS.reject { |field| position.key?(field) }
      return false unless quote_fields_missing.empty? || quote_fields_missing == POSITION_MARKET_DATA_FIELDS

      values = { "qty" => decimal_value(position["qty"]), "bookValue" => decimal_value(position["bookValue"]) }
      unless quote_fields_missing.any?
        POSITION_MARKET_DATA_FIELDS.each { |field| values[field] = decimal_value(position[field]) }
      end
      return false if values["qty"].negative? || values["bookValue"].negative? || values["marketValue"]&.negative? ||
        values["marketPrice"]&.negative?
      return false if values["qty"].zero? && values.values_at("bookValue", "marketValue", "profitLoss").compact.any?(&:nonzero?)
      return false unless OPTIONAL_POSITION_NUMBER_FIELDS.all? do |field|
        !position.key?(field) || position[field].nil? || valid_decimal_value?(position[field])
      end

      true
    rescue InvalidResponse
      false
    end

    def fetch_validated_portfolio!
      attempts = 0

      begin
        response, body = request_endpoint(ENDPOINT, @last_rotated_gsessionid.presence || @gsessionid)
        validate_success_response!(response, body)
        payload = parse_payload(body)
        validate_portfolio!(payload)
      rescue MarketDataUnavailable
        retain_rotated_gsessionid!(response)
        attempts += 1
        retry if attempts < 2

        raise
      end

      retain_rotated_gsessionid!(response)
      payload
    end

    def market_data_unavailable_position?(position)
      missing_market_data_fields?(position) && valid_quote_unavailable_context_position?(position)
    end

    def valid_decimal_value?(value)
      decimal_value(value)
      true
    rescue InvalidResponse
      false
    end

    def validate_summary_totals!(show, total, rows)
      unless show["currencyCd"].casecmp?(total["currencyCd"])
        raise InvalidResponse, "Fineco returned mismatched portfolio currencies."
      end

      tolerance = BigDecimal("0.005") * (rows.size + 1)
      SUMMARY_MONEY_FIELDS.each do |field|
        show_value = decimal_value(show[field])
        total_value = decimal_value(total[field])
        if (show_value - total_value).abs > tolerance
          raise InvalidResponse, "Fineco returned partial portfolio totals."
        end

        if rows.all? { |row| row.key?(field) }
          row_total = rows.sum(BigDecimal("0")) { |row| row[field] }
          if (row_total - total_value).abs > tolerance
            raise InvalidResponse, "Fineco returned incomplete portfolio positions."
          end
        end
      end

      percentage_tolerance = BigDecimal("0.01")
      show_percentage = decimal_value(show["profitLossPerc"])
      total_percentage = decimal_value(total["profitLossPerc"])
      if (show_percentage - total_percentage).abs > percentage_tolerance
        raise InvalidResponse, "Fineco returned partial portfolio totals."
      end
    end

    def decimal_value(value)
      decimal = case value
      when BigDecimal then value
      when Integer, Float then BigDecimal(value.to_s)
      when String then BigDecimal(value)
      else
        raise InvalidResponse, "Fineco returned an invalid portfolio number."
      end

      raise InvalidResponse, "Fineco returned an invalid portfolio number." unless decimal.finite?

      decimal
    rescue ArgumentError
      raise InvalidResponse.new("Fineco returned an invalid portfolio number."), cause: nil
    end

    def rotated_gsessionid_from(response)
      headers = response.get_fields("set-cookie") || []
      session_headers = headers.select do |header|
        header.to_s.split(";", 2).first.to_s.split("=", 2).first.to_s.strip == "gsessionid"
      end
      return nil unless session_headers.one?

      parse_rotation_cookie(session_headers.first)
    end

    def retain_rotated_gsessionid!(response)
      @last_rotated_gsessionid = rotated_gsessionid_from(response) || @last_rotated_gsessionid
    end

    def parse_rotation_cookie(header)
      parts = header.to_s.split(";")
      name, separator, value = parts.shift.to_s.strip.partition("=")
      return nil unless separator == "=" && name == "gsessionid" && value.match?(COOKIE_VALUE_PATTERN)

      attributes = {}
      flags = Set.new
      parts.each do |part|
        key, attr_separator, attr_value = part.strip.partition("=")
        if attr_separator == "="
          normalized_key = key.downcase
          return nil if attributes.key?(normalized_key)

          attributes[normalized_key] = attr_value.strip
        else
          flags.add(key.downcase)
        end
      end

      return nil unless flags.include?("secure")
      return nil unless allowed_cookie_domain?(attributes["domain"])
      return nil unless allowed_cookie_path?(attributes["path"])
      return nil unless cookie_is_current?(attributes)

      value
    rescue ArgumentError
      nil
    end

    def allowed_cookie_domain?(domain)
      return true if domain.blank?

      normalized = domain.downcase.delete_prefix(".")
      %w[finecobank.com private-api.finecobank.com].include?(normalized)
    end

    def allowed_cookie_path?(cookie_path)
      return true if cookie_path.blank?
      return false unless cookie_path.start_with?("/")

      request_path = ENDPOINT.path
      request_path.start_with?(cookie_path) &&
        (cookie_path == "/" || cookie_path.end_with?("/") || request_path.length == cookie_path.length ||
          request_path[cookie_path.length] == "/")
    end

    def cookie_is_current?(attributes)
      if attributes.key?("max-age")
        max_age = Integer(attributes["max-age"], 10)
        return false unless max_age.positive?
      elsif attributes.key?("expires")
        return false if Time.httpdate(attributes["expires"]) <= Time.now
      end

      true
    end

    def validate_cookie!(value)
      unless value.is_a?(String) && value.match?(COOKIE_VALUE_PATTERN)
        raise ConfigurationError, "Fineco session cookie is invalid."
      end

      value
    end

    def validate_index!(value)
      unless value.is_a?(String) && value.match?(INDEX_PATTERN)
        raise ConfigurationError, "Fineco account context is invalid."
      end

      value
    end
end
