# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "json"
require "net/http"
require "openssl"
require "set"
require "timeout"
require "time"
require "uri"

class Provider::Fineco
  ACCOUNT_LIST_ENDPOINT = URI("https://private-api.finecobank.com/v1/private/users/accounts").freeze
  ENDPOINT = URI("https://private-api.finecobank.com/v1/private/tol/positions/summary?type=sintesi").freeze
  HOST = "private-api.finecobank.com".freeze
  PORTFOLIO_REFERER = "https://finecobank.com/pvt/portfolio/trading-summary/home".freeze

  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 10
  WRITE_TIMEOUT_SECONDS = 5
  TOTAL_TIMEOUT_SECONDS = 30
  MAX_BODY_BYTES = 2 * 1024 * 1024
  MAX_POSITION_COUNT = 2_000
  MAX_FILTER_VALUE_COUNT = 256

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

  def initialize(gsessionid:, account_index:, dossier_index:)
    @gsessionid = validate_cookie!(gsessionid)
    @account_index = validate_index!(account_index)
    @dossier_index = validate_index!(dossier_index)
  end

  def self.verified_identity_contract?
    false
  end

  def fetch_portfolio_summary
    unless self.class.verified_identity_contract?
      raise IdentityVerificationRequired, "Fineco account identity verification is required."
    end

    ::Timeout.timeout(TOTAL_TIMEOUT_SECONDS, RequestTimeout, "Fineco request timed out.") do
      identity_response, identity_body = request_endpoint(ACCOUNT_LIST_ENDPOINT, @gsessionid)
      validate_success_response!(identity_response, identity_body)
      identity = selected_bank_identity!(parse_payload(identity_body))
      identity_cookie = rotated_gsessionid_from(identity_response)

      portfolio_response, portfolio_body = request_endpoint(ENDPOINT, identity_cookie.presence || @gsessionid)
      validate_success_response!(portfolio_response, portfolio_body)
      payload = parse_payload(portfolio_body)
      validate_portfolio!(payload)

      PortfolioResult.new(
        payload: payload,
        rotated_gsessionid: rotated_gsessionid_from(portfolio_response) || identity_cookie,
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

  def inspect
    "#<#{self.class.name}: authenticated client>"
  end
  alias to_s inspect

  private

    def request_endpoint(uri, gsessionid)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true if http.respond_to?(:verify_hostname=)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.write_timeout = WRITE_TIMEOUT_SECONDS
      http.max_retries = 0 if http.respond_to?(:max_retries=)

      request = Net::HTTP::Get.new(uri.request_uri)
      STATIC_HEADERS.each { |key, value| request[key] = value }
      request["X-Account-Index"] = @account_index
      request["X-Dossier-Index"] = @dossier_index
      request["Cookie"] = "gsessionid=#{gsessionid}"

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

      account_matches = accounts.select do |account|
        account.is_a?(Hash) && selected_index?(account["index"], @account_index)
      end
      unless account_matches.one?
        raise InvalidResponse, "Fineco could not verify the selected account."
      end

      account = account_matches.first
      account_number = account["number"]
      unless account_number.is_a?(String) && account_number == account_number.strip &&
             account_number.present? && account_number.length <= 128 && !account_number.match?(/[\x00-\x1F\x7F]/)
        raise InvalidResponse, "Fineco could not verify the selected account."
      end

      dossiers = account["dossiers"]
      unless dossiers.is_a?(Array) && dossiers.size <= MAX_POSITION_COUNT
        raise InvalidResponse, "Fineco returned an incomplete dossier selection response."
      end

      dossier_matches = dossiers.select do |dossier|
        dossier.is_a?(Hash) && selected_index?(dossier["index"], @dossier_index)
      end
      unless dossier_matches.one? && (dossier_matches.first.keys - [ "index" ]).any?
        raise InvalidResponse, "Fineco could not verify the selected dossier."
      end

      dossier_fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical_json_value(dossier_matches.first)))
      { account_number: account_number, dossier_identity: dossier_fingerprint }
    end

    def selected_index?(value, expected)
      case value
      when Integer then value.to_s == expected
      when String then value.match?(INDEX_PATTERN) && value == expected
      else false
      end
    end

    def canonical_json_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, result|
          result[key] = canonical_json_value(value.fetch(key))
        end
      when Array
        value.map { |entry| canonical_json_value(entry) }
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        raise InvalidResponse, "Fineco returned an unsupported account selection value."
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
      rows = validate_positions!(positions)
      validate_summary_totals!(show, total, rows)
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
      positions.map do |position|
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

        row_total = rows.sum { |row| row[field] || BigDecimal("0") }
        if (row_total - total_value).abs > tolerance
          raise InvalidResponse, "Fineco returned incomplete portfolio positions."
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
