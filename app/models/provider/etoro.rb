class Provider::Etoro
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class ApiError < Error
    attr_reader :status_code, :response_body

    def initialize(message, status_code: nil, response_body: nil)
      super(message)
      @status_code = status_code
      @response_body = response_body
    end
  end
  # Still throttled after waiting out eToro's Retry-After.
  class RateLimitError < ApiError; end
  # The request did not get through or came back unreadable. A later sync
  # can expect it to succeed.
  class TransientError < ApiError; end
  # An account Sure cannot import correctly, such as one not held in USD.
  class UnsupportedAccountError < Error; end

  BASE_URI = "https://public-api.etoro.com/api/v1".freeze

  TRADE_HISTORY_PAGE_SIZE = 500
  INSTRUMENT_BATCH_SIZE = 50
  CANDLE_PAGE_LIMIT = 2000
  ADJUSTED_CANDLE_COUNT = 1000
  # A safety stop for one instrument's candle pages, far above any history.
  MAX_CANDLE_PAGES = 10
  # eToro meters its data and its market-data endpoints separately, at 120
  # requests a minute each. Price history requests to one of them are spaced
  # this many seconds apart.
  PRICE_REQUEST_INTERVAL = 0.5
  MAX_RATE_LIMIT_RETRIES = 2
  MAX_RATE_LIMIT_WAIT = 60
  MAX_SERVER_ERROR_RETRIES = 2
  SERVER_ERROR_STATUSES = [ 502, 503, 504 ].freeze

  # Failures before eToro's answer was read in full: HTTParty's network
  # errors (refused, reset or unreachable connections, broken pipes,
  # malformed responses, refused proxy tunnels and every timeout), closed
  # streams, and compressed bodies cut short.
  RETRYABLE_ERRORS = [
    *HTTParty::COMMON_NETWORK_ERRORS,
    IOError,
    Zlib::Error
  ].uniq.freeze

  default_options.merge!({ timeout: 60 }.merge(httparty_ssl_options))

  attr_reader :api_key, :user_key

  def initialize(api_key:, user_key:)
    raise ConfigurationError, "api_key is required" if api_key.blank?
    raise ConfigurationError, "user_key is required" if user_key.blank?

    @api_key = api_key.to_s.strip
    @user_key = user_key.to_s.strip
  end

  # Current value of each account. Trading balances are equity (cash, margin
  # in positions and unrealised P&L), with spendable cash under equityDetails.
  # eToro leaves accounts with a zero balance out unless asked for them.
  def fetch_balances(account_types: "Trading")
    get("/balances", query: { accountTypes: account_types, includeZeroBalances: true, expand: "equityDetails" })
  end

  # Open positions of the real account, its copy-trading mirrors among them,
  # each with its unrealised P&L.
  def fetch_portfolio
    get("/trading/info/real/pnl")
  end

  # One page of closed trades, newest close first. Pages count from 1, a page
  # can hold fewer than pageSize trades with more pages after it, and the
  # first empty page is past the end. min_date does not bound the close
  # dates: eToro also returns trades closed well before it.
  def fetch_trade_history_page(min_date:, page:)
    data = get("/trading/info/trade/history", query: {
      minDate: min_date.iso8601,
      page: page,
      pageSize: TRADE_HISTORY_PAGE_SIZE
    })

    trades = data.is_a?(Hash) ? (data["trades"] || data["items"]) : data
    raise ApiError.new("eToro returned an unexpected trade history response", status_code: 200) unless trades.is_a?(Array)

    trades
  end

  # End-of-day snapshots of one account, available for the last 12 months.
  def fetch_balance_history(account_type:, account_id:, from_date:, to_date:)
    path = "/balances/#{account_type.to_s.downcase}/#{ERB::Util.url_encode(account_id.to_s)}/history"
    get(path, query: { fromDate: from_date.iso8601, toDate: to_date.iso8601 })
  end

  def fetch_instruments(instrument_ids)
    Array(instrument_ids).compact.uniq.each_slice(INSTRUMENT_BATCH_SIZE).flat_map do |ids|
      data = get("/market-data/instruments", query: { instrumentIds: ids.join(",") })
      instruments = data.is_a?(Hash) ? data["instrumentDisplayDatas"] : nil
      raise ApiError.new("eToro returned an unexpected instruments response", status_code: 200) unless instruments.is_a?(Array)

      instruments
    end
  end

  # One instrument's daily candles, newest first, with the pair eToro quotes
  # it as ("ABCD/USD", "LONX.l/GBX"). The prices are eToro's bid as traded on
  # the day: a split shows as a jump. eToro sends the candles that open from
  # `from` until `to`, a day's at 17:00 New York time the evening before it.
  # Every page is read; eToro takes a `to` past its newest candle.
  def fetch_daily_candles(instrument_id, from:, to: Date.current.tomorrow)
    path = "/data/instruments/#{ERB::Util.url_encode(instrument_id.to_s)}/candles"
    query = { interval: "1d", from: candle_time(from), to: candle_time(to), limit: CANDLE_PAGE_LIMIT }
    results = []
    symbol = nil

    MAX_CANDLE_PAGES.times do
      data = get(path, query: query, quota: :data)
      page = data.is_a?(Hash) ? data["results"] : nil
      raise ApiError.new("eToro returned an unexpected candles response", status_code: 200) unless page.is_a?(Array)

      symbol ||= data["symbol"]
      results.concat(page)
      pagination = data["pagination"].is_a?(Hash) ? data["pagination"] : {}
      cursor = pagination["nextCursor"] if pagination["hasNext"]
      return { "symbol" => symbol, "results" => results } if cursor.blank?

      query = query.merge(cursor: cursor)
    end

    raise ApiError.new("eToro sent more than #{MAX_CANDLE_PAGES} pages of candles", status_code: 200)
  end

  # The newest `count` daily ("OneDay") or weekly ("OneWeek") candles of one
  # instrument, adjusted for splits but not for dividends.
  def fetch_adjusted_candles(instrument_id, interval:, count: ADJUSTED_CANDLE_COUNT)
    path = "/market-data/instruments/#{ERB::Util.url_encode(instrument_id.to_s)}/history/candles/desc/#{interval}/#{count}"
    data = get(path, quota: :market_data)
    groups = data.is_a?(Hash) ? data["candles"] : nil
    raise ApiError.new("eToro returned an unexpected candles response", status_code: 200) unless groups.is_a?(Array)

    groups.flat_map { |group| group.is_a?(Hash) ? Array(group["candles"]) : [] }
  end

  private

    def request_headers
      {
        "x-api-key" => api_key,
        "x-user-key" => user_key,
        "x-request-id" => SecureRandom.uuid,
        "Accept" => "application/json",
        "User-Agent" => "Sure Finance eToro Client"
      }
    end

    # A request for price history names the eToro quota it draws on, which
    # spaces it from the last request to that quota.
    def get(path, query: {}, quota: nil)
      url = "#{BASE_URI}#{path}"
      rate_limit_retries = 0
      server_error_retries = 0

      loop do
        response = with_retries(path) do
          pace(quota) if quota
          self.class.get(url, headers: request_headers, query: query.compact)
        end

        if response.code == 429 && rate_limit_retries < MAX_RATE_LIMIT_RETRIES
          rate_limit_retries += 1
          sleep(retry_after(response))
          next
        end

        if SERVER_ERROR_STATUSES.include?(response.code) && server_error_retries < MAX_SERVER_ERROR_RETRIES
          server_error_retries += 1
          sleep(2**server_error_retries)
          next
        end

        return handle_response(response, quota: quota)
      end
    end

    def pace(quota)
      @requested_at ||= {}
      wait = @requested_at[quota] && @requested_at[quota] + PRICE_REQUEST_INTERVAL - monotonic_now
      sleep(wait) if wait&.positive?
      @requested_at[quota] = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def candle_time(value)
      value.in_time_zone("UTC").iso8601
    end

    def retry_after(response)
      seconds = response.headers&.[]("retry-after").to_i
      seconds.positive? ? [ seconds, MAX_RATE_LIMIT_WAIT ].min : MAX_RATE_LIMIT_WAIT
    end

    def handle_response(response, quota: nil)
      case response.code
      when 200
        parse_body(response)
      when 401, 403
        # eToro has refused its market data with a 403 for a while and then
        # served the same key again, so a 403 there is worth a later try,
        # not new keys.
        if quota && response.code == 403
          raise TransientError.new("eToro withheld its market data (status 403)", status_code: 403, response_body: response.body)
        end

        raise AuthenticationError, "eToro authentication failed (#{response.code}). Check your API key and user key."
      when 429
        raise RateLimitError.new(
          "eToro rate limit exceeded. Please wait before retrying.",
          status_code: response.code,
          response_body: response.body
        )
      when *SERVER_ERROR_STATUSES
        raise TransientError.new(
          "eToro API unavailable (status #{response.code})",
          status_code: response.code,
          response_body: response.body
        )
      else
        raise ApiError.new(
          "eToro API error (status #{response.code})",
          status_code: response.code,
          response_body: response.body
        )
      end
    end

    # eToro answers in JSON. Anything else, such as a proxy's error page or a
    # body cut short, is a failed request rather than data.
    def parse_body(response)
      body = response.parsed_response
      body.is_a?(String) ? JSON.parse(body) : body
    rescue JSON::ParserError
      raise TransientError.new("eToro returned a response that is not JSON", status_code: response.code)
    end

    def with_retries(label, max_retries: 3)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue *RETRYABLE_ERRORS => e
        raise TransientError, "eToro #{label} request failed: #{e.class}: #{e.message}" if attempt >= max_retries

        delay = [ 2**attempt, 30 ].min
        DebugLogEntry.capture(
          category: "sync",
          level: "warn",
          message: "Provider::Etoro #{label} attempt #{attempt} failed: #{e.message}. Retrying in #{delay}s",
          source: "etoro",
          provider_key: "etoro"
        )
        sleep(delay)
        retry
      end
    end
end
