require "digest"
require "json"

# One physical GET per action. Cookie/crumb envelopes contain secrets and must
# only enter encrypted capture evidence. The caller must resolve them from the
# exact admitted Sync prefix before calling this reader; hashes alone do not
# prove that ownership. No cache, refresh, inverse fallback or retry happens here.
class Provider::AccountData::OnchainWallet::YahooFxReader
  PROVIDER = "yahoo_finance".freeze
  POLICY = "yahoo-fx-actions/v1".freeze
  COOKIE_ENDPOINT = "https://fc.yahoo.com".freeze
  MAX_BYTES = 1024 * 1024
  MAX_HEADER_BYTES = 8192
  MAX_COOKIE_BYTES = 4096
  MAX_CRUMB_BYTES = 1024
  MAX_AUTH_AGE = 3600
  MAX_OBSERVATIONS = 32
  LOOKBACK_DAYS = 10
  ACTIONS = %w[cookie crumb chart].freeze
  STATUSES = %w[response authentication_failed auth_expired pair_unavailable request_failed invalid_response].freeze
  ENVELOPE_KEYS = %w[action configuration http_status policy provider request requested_at response status version].freeze

  class Http
    include HTTParty
    extend SslConfigurable
    default_options.merge!({ timeout: 20, max_retries: 0 }.merge(httparty_ssl_options))
  end

  attr_reader :configuration

  def initialize(options:, http: Http)
    values = options.deep_stringify_keys
    raise ArgumentError unless values["version"] == 1 && values["provider"] == PROVIDER
    @endpoint = Provider::AccountData::OnchainWallet::Readers::Transport.endpoint(values.fetch("endpoint"))
    raise ArgumentError if URI.parse(@endpoint).query
    @user_agent = values.fetch("user_agent")
    raise ArgumentError unless @user_agent.is_a?(String) && @user_agent.bytesize.between?(1, 512) && @user_agent.match?(/\A[\x20-\x7e]+\z/)
    @interval = Float(values.fetch("min_interval_seconds"))
    raise ArgumentError unless @interval.finite? && @interval.between?(0, 60)
    @endpoint, @user_agent = @endpoint.dup.freeze, @user_agent.dup.freeze
    @configuration = self.class.digest({ "policy" => POLICY, "endpoint" => @endpoint, "cookie_endpoint" => COOKIE_ENDPOINT,
      "user_agent" => @user_agent, "min_interval_seconds" => @interval.to_s }).freeze
    @http = http
  rescue ArgumentError, TypeError, KeyError
    raise ArgumentError, "Invalid captured Yahoo FX configuration", cause: nil
  end

  # auth: { "cookie" => captured_cookie, "crumb" => captured_crumb }. The crumb
  # is not needed for the crumb action. The planner, not this method, bounds the
  # number of actions, commits each result and decides whether to refresh auth.
  def read(action:, from:, to:, date:, auth_generation:, requested_at: nil, request_clock: nil, direction: nil, auth: {})
    request = self.class.request(action: action, from: from, to: to, date: date, auth_generation: auth_generation, direction: direction)
    unless (requested_at.is_a?(Time) && request_clock.nil?) || (requested_at.nil? && request_clock.respond_to?(:call))
      raise ArgumentError, "Yahoo FX requires one explicit request clock"
    end
    if ApplicationRecord.connection.transaction_open?
      raise Provider::AccountData::InvalidResponse, "Yahoo FX requests cannot run in a database transaction"
    end
    # Production supplies a clock, sampled only after the final pacing delay.
    # Expiry and the captured request time must describe physical dispatch, not
    # entry into an earlier coordinator/client call. Replay reads the envelope.
    pace!
    sampled = request_clock ? request_clock.call : requested_at
    raise ArgumentError, "Yahoo FX requires an explicit request clock" unless sampled.is_a?(Time)
    at = sampled.getutc
    headers = { "User-Agent" => @user_agent, "Accept" => action == "chart" ? "application/json" : "*/*", "Accept-Language" => "en-US,en;q=0.9" }
    query = {}
    unless action == "cookie"
      cookie, crumb = admitted_auth(auth, request: request, at: at, chart: action == "chart")
      return envelope(action, request, at, "auth_expired") unless cookie
      headers["Cookie"] = cookie.fetch("response").fetch("cookie")
    end
    url = case action
    when "cookie" then COOKIE_ENDPOINT
    when "crumb" then "#{@endpoint}/v1/test/getcrumb"
    when "chart"
      query = { period1: self.class.midnight(date - LOOKBACK_DAYS), period2: self.class.midnight(date + 1),
        interval: "1d", includeAdjustedClose: true, crumb: crumb.fetch("response").fetch("crumb") }
      headers.merge!("Cache-Control" => "no-cache", "Pragma" => "no-cache")
      "#{@endpoint}/v8/finance/chart/#{ERB::Util.url_encode(self.class.symbol(from, to, direction))}"
    end
    response = @http.get(url, query: query, headers: headers, follow_redirects: false)
    code = response.code.to_i
    reject_transient!(code)
    return envelope(action, request, at, "authentication_failed", code: code) if [ 401, 403 ].include?(code)
    unless code.between?(200, 299) || (action == "cookie" && code == 404)
      status = action == "chart" && code == 404 ? "pair_unavailable" : "request_failed"
      return envelope(action, request, at, status, code: code)
    end
    case action
    when "cookie"
      captured_cookie(response, request, at, code)
    when "crumb"
      captured_crumb(response, request, at, code, cookie)
    when "chart"
      captured_chart(response, request, at, code)
    end
  rescue *Provider::HttpTransport::TRANSPORT_ERRORS
    raise Provider::AccountData::OnchainWallet::Readers::Error, "Yahoo FX endpoint is unavailable", cause: nil
  end

  # Pure replay normalization. Keep unavailable and a valid empty series distinct
  # in the envelope: legacy direct [] does not trigger the inverse-pair fallback.
  def self.rate(capture, from:, to:, date:, auth_generation:, direction:)
    expected = request(action: "chart", from: from, to: to, date: date, auth_generation: auth_generation, direction: direction)
    validate_envelope!(capture, action: "chart", request: expected)
    return unless capture["status"] == "response" && capture["http_status"].between?(200, 299)
    data = capture.fetch("response")
    raise ArgumentError unless data.keys.sort == %w[observations symbol] && data["symbol"] == symbol(from, to, direction)
    rows = data.fetch("observations")
    raise ArgumentError unless rows.is_a?(Array) && rows.size <= MAX_OBSERVATIONS
    candidates = rows.filter_map do |row|
      raise ArgumentError unless row.is_a?(Hash) && row.keys.sort == %w[close timestamp]
      day = timestamp_date(row.fetch("timestamp"))
      value = decimal(row["close"]) unless row["close"].nil?
      [ day, value ] if value&.positive? && day.between?(date - LOOKBACK_DAYS, date)
    end
    grouped = candidates.group_by(&:first)
    return if grouped.any? { |_day, values| values.map(&:last).uniq.size > 1 }
    day, value = candidates.max_by(&:first)
    return unless value
    result = direction == "inverse" ? (BigDecimal("1") / value).round(12) : value
    return unless result.positive?
    { "rate" => result.to_s("F"), "date" => day.iso8601, "provider" => PROVIDER, "source" => "provider_response",
      "direction" => direction, "symbol" => data.fetch("symbol"), "source_rate" => value.to_s("F"), "source_date" => day.iso8601 }
  rescue ArgumentError, TypeError, KeyError, NoMethodError
    nil
  end

  def self.request(action:, from:, to:, date:, auth_generation:, direction: nil)
    raise ArgumentError unless ACTIONS.include?(action) && auth_generation.is_a?(Integer) && auth_generation.between?(0, 2)
    valid_direction = action == "chart" ? %w[direct inverse].include?(direction) : direction.nil?
    raise ArgumentError unless valid_direction
    result = Provider::AccountData::OnchainWallet::FxReader.request(from: from, to: to, date: date).merge("auth_generation" => auth_generation)
    result["direction"] = direction if direction
    result
  rescue ArgumentError
    raise ArgumentError, "Invalid Yahoo FX action", cause: nil
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def admitted_auth(auth, request:, at:, chart:)
      raise ArgumentError unless auth.is_a?(Hash) && auth.keys.sort == (chart ? %w[cookie crumb] : %w[cookie])
      base_request = request.except("direction")
      cookie = auth.fetch("cookie")
      self.class.validate_envelope!(cookie, action: "cookie", request: base_request, configuration: configuration)
      values = cookie.fetch("response")
      raise ArgumentError unless cookie["status"] == "response" && values.keys.sort == %w[cookie expires_at]
      raise ArgumentError unless self.class.valid_cookie?(values["cookie"])
      created = self.class.exact_time(cookie.fetch("requested_at"))
      expires = self.class.exact_time(values.fetch("expires_at"))
      raise ArgumentError unless expires > created && expires <= created + MAX_AUTH_AGE && at >= created
      return if at >= expires
      if chart
        crumb = auth.fetch("crumb")
        self.class.validate_envelope!(crumb, action: "crumb", request: base_request, configuration: configuration)
        details = crumb.fetch("response")
        raise ArgumentError unless crumb["status"] == "response" && details.keys.sort == %w[cookie_digest crumb expires_at]
        raise ArgumentError unless details["cookie_digest"] == self.class.digest(cookie) && details["expires_at"] == values["expires_at"]
        crumb_at = self.class.exact_time(crumb.fetch("requested_at"))
        raise ArgumentError unless crumb_at >= created && crumb_at < expires && crumb_at <= at && self.class.valid_crumb?(details["crumb"])
      end
      [ cookie, crumb ]
    rescue ArgumentError, TypeError, KeyError
      raise Provider::AccountData::StaleWriter, "Yahoo FX authentication does not match captured context", cause: nil
    end

    def captured_cookie(response, request, at, code)
      header = response.headers["set-cookie"]
      return envelope("cookie", request, at, "invalid_response", code: code) unless header.is_a?(String) && header.bytesize <= MAX_HEADER_BYTES
      parts = header.split(";").map(&:strip)
      value = parts.shift
      return envelope("cookie", request, at, "authentication_failed", code: code) unless self.class.valid_cookie?(value)
      ages = parts.select { |part| part.match?(/\AMax-Age=/i) }
      raise ArgumentError if ages.size > 1 || (ages.any? && !ages.first.match?(/\AMax-Age=-?\d{1,12}\z/i))
      age = ages.any? ? [ ages.first.split("=").last.to_i, MAX_AUTH_AGE ].min : MAX_AUTH_AGE
      return envelope("cookie", request, at, "auth_expired", code: code) unless age.positive?
      envelope("cookie", request, at, "response", code: code, response: { "cookie" => value, "expires_at" => (at + age).iso8601(9) })
    rescue ArgumentError
      envelope("cookie", request, at, "invalid_response", code: code)
    end

    def captured_crumb(response, request, at, code, cookie)
      body = response.body
      return envelope("crumb", request, at, "invalid_response", code: code) unless body.is_a?(String) && body.bytesize <= MAX_CRUMB_BYTES
      value = body.strip
      reject_transient!(429) if value.casecmp?("Too Many Requests")
      return envelope("crumb", request, at, "authentication_failed", code: code) unless self.class.valid_crumb?(value)
      envelope("crumb", request, at, "response", code: code, response: { "crumb" => value, "cookie_digest" => self.class.digest(cookie),
        "expires_at" => cookie.fetch("response").fetch("expires_at") })
    end

    def captured_chart(response, request, at, code)
      body = response.body
      raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_BYTES
      data = JSON.parse(body, decimal_class: BigDecimal)
      chart = data.fetch("chart")
      raise ArgumentError unless chart.is_a?(Hash)
      if chart["error"]
        error = chart.fetch("error")
        raise ArgumentError unless error.is_a?(Hash)
        status = error["code"] == "Unauthorized" ? "authentication_failed" : "pair_unavailable"
        return envelope("chart", request, at, status, code: code)
      end
      return envelope("chart", request, at, "pair_unavailable", code: code) if chart["result"].nil? || chart["result"] == []
      raise ArgumentError unless chart["result"].is_a?(Array) && chart["result"].size == 1
      result = chart.fetch("result").first
      expected_symbol = self.class.symbol(request.fetch("from"), request.fetch("to"), request.fetch("direction"))
      raise ArgumentError unless result.is_a?(Hash) && result.dig("meta", "symbol") == expected_symbol
      timestamps = result["timestamp"] || []
      quotes = result.dig("indicators", "quote")
      raise ArgumentError unless timestamps.is_a?(Array) && timestamps.size <= MAX_OBSERVATIONS
      closes = if quotes.nil? || quotes == []
        []
      else
        raise ArgumentError unless quotes.is_a?(Array) && quotes.size == 1 && quotes.first.is_a?(Hash)
        quotes.first["close"] || []
      end
      raise ArgumentError unless closes.is_a?(Array) && closes.size == timestamps.size
      rows = timestamps.zip(closes).map do |timestamp, close|
        self.class.timestamp_date(timestamp)
        { "timestamp" => timestamp, "close" => close.nil? ? nil : self.class.decimal(close).to_s("F") }
      end
      envelope("chart", request, at, "response", code: code, response: { "symbol" => expected_symbol, "observations" => rows })
    rescue ArgumentError, TypeError, KeyError, NoMethodError, JSON::ParserError
      envelope("chart", request, at, "invalid_response", code: code)
    end

    def pace!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep([ @interval - (now - @last_request_at), 0 ].max) if @last_request_at
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def reject_transient!(code)
      if code == 429
        raise Provider::AccountData::OnchainWallet::Readers::RateLimited, "Yahoo FX endpoint rate limit exceeded", cause: nil
      elsif code.between?(500, 599)
        raise Provider::AccountData::OnchainWallet::Readers::Error, "Yahoo FX endpoint is unavailable", cause: nil
      end
    end

    def envelope(action, request, at, status, code: nil, response: {})
      Provider::AccountData::MigrationManifest.copy_value({ "version" => 1, "policy" => POLICY, "provider" => PROVIDER,
        "configuration" => configuration, "action" => action, "request" => request, "requested_at" => at.iso8601(9),
        "status" => status, "http_status" => code, "response" => response })
    end

    class << self
      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      def validate_envelope!(value, action:, request:, configuration: nil)
        raise ArgumentError unless value.is_a?(Hash) && value.keys.sort == ENVELOPE_KEYS && value["version"] == 1 && value["policy"] == POLICY &&
          value["provider"] == PROVIDER && value["action"] == action && value["request"] == request && STATUSES.include?(value["status"]) && value["response"].is_a?(Hash)
        raise ArgumentError unless value["configuration"].is_a?(String) && value["configuration"].match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError if configuration && value["configuration"] != configuration
        code = value["http_status"]
        raise ArgumentError unless code.nil? || (code.is_a?(Integer) && code.between?(100, 599))
        if value["status"] == "response"
          raise ArgumentError unless code && (code.between?(200, 299) || (action == "cookie" && code == 404))
        end
        exact_time(value["requested_at"])
      end

      def exact_time(value)
        raise ArgumentError unless value.is_a?(String) && value.bytesize == 30
        time = Time.iso8601(value)
        raise ArgumentError unless time.getutc.iso8601(9) == value
        time
      end

      def valid_cookie?(value)
        value.is_a?(String) && value.bytesize.between?(1, MAX_COOKIE_BYTES) && value.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+=[\x21-\x2b\x2d-\x3a\x3c-\x7e]+\z/)
      end

      def valid_crumb?(value)
        value.is_a?(String) && value.bytesize.between?(1, MAX_CRUMB_BYTES) && value.match?(/\A[\x21-\x7e]+\z/) && !value.casecmp?("Too Many Requests")
      end

      def symbol(from, to, direction)
        "#{direction == 'inverse' ? to + from : from + to}=X"
      end

      def midnight(date)
        Time.utc(date.year, date.month, date.day).to_i
      end

      def timestamp_date(value)
        raise ArgumentError unless value.is_a?(Integer) && value.between?(1, 253_402_300_799)
        Time.at(value).getutc.to_date
      end

      def decimal(value)
        raise ArgumentError unless value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.bytesize <= 128)
        number = BigDecimal(value.to_s)
        raise ArgumentError unless number.finite? && number.exponent.abs <= 64 && number.precs.first <= 128
        number
      end
    end
end
