require "base64"
require "bigdecimal"

class Provider::Saxo
  API_URL = "https://gateway.saxobank.com/openapi"
  AUTH_URL = "https://live.logonvalidation.net"
  PAGE_SIZE = 100
  RATE_LIMIT_RETRIES = 2
  MAX_RATE_LIMIT_WAIT = 60

  class Error < StandardError
    attr_reader :diagnostic

    def initialize(message, diagnostic: {})
      super(message)
      @diagnostic = diagnostic
    end
  end
  class AuthenticationError < Error; end

  def self.configured?
    Setting.saxo_app_key.present? && Setting.saxo_app_secret.present?
  end

  def self.application_key_digest
    Digest::SHA256.hexdigest(Setting.saxo_app_key.to_s)
  end

  def self.exchange(data)
    raise AuthenticationError, "Saxo application is not configured" unless configured?
    response = Faraday.post("#{AUTH_URL}/token") do |request|
      request.options.timeout = 30
      request.options.open_timeout = 10
      request.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{Setting.saxo_app_key}:#{Setting.saxo_app_secret}")}"
      request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(data)
    end
    unless response.success?
      oauth_error = begin
        parsed = JSON.parse(response.body)
        parsed["error"] if parsed.is_a?(Hash)
      rescue JSON::ParserError, TypeError
        nil
      end
      known_errors = %w[invalid_request invalid_client invalid_grant unauthorized_client unsupported_grant_type invalid_scope access_denied]
      diagnostic = { stage: "token_exchange", reason: "http_error", http_status: response.status }
      diagnostic[:oauth_error] = oauth_error if known_errors.include?(oauth_error)
      error_class = response.status == 429 || response.status >= 500 ? Error : AuthenticationError
      raise error_class.new("Saxo authorization service rejected the request", diagnostic: diagnostic)
    end
    payload = JSON.parse(response.body)
    unless payload.is_a?(Hash)
      raise AuthenticationError.new("Saxo returned incomplete authorization", diagnostic: { stage: "token_exchange", reason: "invalid_response" })
    end
    required_fields = %w[access_token refresh_token expires_in refresh_token_expires_in]
    missing_fields = required_fields.select { |field| payload[field].blank? }
    if missing_fields.any?
      raise AuthenticationError.new("Saxo returned incomplete authorization", diagnostic: {
        stage: "token_exchange", reason: "missing_fields", missing_fields: missing_fields
      })
    end
    access_lifetime = Integer(payload.fetch("expires_in"))
    refresh_lifetime = Integer(payload.fetch("refresh_token_expires_in"))
    unless payload["access_token"].is_a?(String) && payload["access_token"].present? &&
        payload["refresh_token"].is_a?(String) && payload["refresh_token"].present? &&
        access_lifetime.positive? && refresh_lifetime.positive?
      raise AuthenticationError.new("Saxo returned incomplete authorization", diagnostic: { stage: "token_exchange", reason: "invalid_fields" })
    end
    {
      access_token: payload["access_token"],
      refresh_token: payload["refresh_token"],
      access_expires_at: Time.current + access_lifetime,
      refresh_expires_at: Time.current + refresh_lifetime
    }
  rescue Faraday::Error
    raise Error.new("Saxo authorization service is temporarily unavailable", diagnostic: { stage: "token_exchange", reason: "network_error" })
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError
    raise AuthenticationError.new("Saxo authorization failed; reconnect", diagnostic: { stage: "token_exchange", reason: "invalid_response" })
  end

  def initialize(item)
    @item = item
  end

  def get(path, params = {})
    refreshed = false
    force_refresh = false
    rate_limit_retries = 0
    rejected_token = nil
    loop do
      token = if force_refresh
        @item.access_token!(force_refresh: true, rejected_token: rejected_token)
      else
        @item.access_token!(force_refresh: false)
      end
      force_refresh = false
      response = Faraday.get("#{API_URL}#{path}", params) do |request|
        request.options.timeout = 30
        request.options.open_timeout = 10
        request.headers["Authorization"] = "Bearer #{token}"
      end
      if response.status == 401 && !refreshed
        refreshed = true
        force_refresh = true
        rejected_token = token
        next
      end
      raise AuthenticationError, "Saxo authorization expired; reconnect" if response.status == 401
      if response.status == 429
        delay = rate_limit_delay(response, rate_limit_retries)
        if rate_limit_retries < RATE_LIMIT_RETRIES && delay <= MAX_RATE_LIMIT_WAIT
          rate_limit_retries += 1
          sleep(delay)
          next
        end
        raise Error.new("Saxo request failed (HTTP 429)", diagnostic: {
          stage: "request", reason: "rate_limited", retry_after_seconds: delay
        })
      end
      raise Error, "Saxo request failed (HTTP #{response.status})" unless response.status == 200
      payload = JSON.parse(response.body, decimal_class: BigDecimal)
      raise Error, "Saxo response is not an object" unless payload.is_a?(Hash)
      return payload
    end
  rescue Faraday::Error, JSON::ParserError
    raise Error, "Saxo request failed"
  end

  def collection(path, params = {})
    result = []
    offset = 0
    loop do
      payload = get(path, params.merge("$top" => PAGE_SIZE, "$skip" => offset))
      page = payload["Data"]
      raise Error, "Saxo collection is incomplete" unless page.is_a?(Array) && page.all? { |row| row.is_a?(Hash) }
      result.concat(page)
      if payload["__next"].blank?
        raise Error, "Saxo collection was truncated" if payload["__count"] && Integer(payload["__count"]) > result.length
        return result
      end
      following = URI.parse(payload["__next"])
      unless [ nil, "gateway.saxobank.com" ].include?(following.host) &&
          (following.host.nil? || following.scheme == "https") &&
          [ path, "/openapi#{path}" ].include?(following.path) && following.fragment.nil?
        raise Error, "Saxo pagination points outside the requested resource"
      end
      next_offset = Integer(URI.decode_www_form(following.query.to_s).to_h.fetch("$skip"))
      raise Error, "Saxo pagination did not advance" if page.empty? || next_offset != offset + page.length
      offset = next_offset
    end
  rescue URI::InvalidURIError, KeyError, ArgumentError, TypeError
    raise Error, "Saxo pagination is invalid"
  end

  def accounts
    collection("/port/v1/accounts/me")
  end

  def balances(account)
    get("/port/v1/balances", account_params(account))
  end

  def positions(account)
    collection("/port/v1/positions", account_params(account).merge("FieldGroups" => "PositionBase,PositionView,DisplayAndFormat"))
  end

  def history(account, since:, until_date: Date.current)
    (since.year..until_date.year).flat_map do |year|
      collection(
        "/hist/v1/transactions",
        "ClientKey" => account.fetch("ClientKey"),
        "AccountKeys" => account.fetch("AccountKey"),
        "FromDate" => [ since, Date.new(year, 1, 1) ].max.iso8601,
        "ToDate" => [ until_date, Date.new(year, 12, 31) ].min.iso8601
      )
    end
  end

  private
    def rate_limit_delay(response, attempt)
      headers = response.headers
      delays = [ headers["retry-after"] ]
      headers.each do |name, value|
        match = /\Ax-ratelimit-(.+)-remaining\z/i.match(name.to_s)
        next unless match && value.to_s == "0"
        delays << headers["x-ratelimit-#{match[1]}-reset"]
      end
      seconds = delays.filter_map do |value|
        next unless value.to_s.match?(/\A\d{1,9}\z/)
        value.to_i
      end
      [ seconds.max || 2**(attempt + 1), 1 ].max
    end

    def account_params(account)
      { "ClientKey" => account.fetch("ClientKey"), "AccountKey" => account.fetch("AccountKey") }
    end
end
