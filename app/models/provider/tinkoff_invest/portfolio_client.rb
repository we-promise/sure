# T-Bank (Tinkoff) Invest brokerage REST API client for portfolio sync.
# Uses the per-family read-only token and shares instrument helpers with
# Provider::TinkoffInvest (which remains the global market-data provider).
class Provider::TinkoffInvest::PortfolioClient
  include Provider::RateLimitable
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class RateLimitError < Error; end

  class ApiError < Error
    attr_reader :status_code, :response_body

    def initialize(message, status_code: nil, response_body: nil)
      super(message)
      @status_code = status_code
      @response_body = response_body
    end
  end

  LIVE_BASE_URL = "https://invest-public-api.tbank.ru/rest".freeze
  SANDBOX_BASE_URL = "https://sandbox-invest-public-api.tbank.ru/rest".freeze

  # OperationsService allows 200 req/min; 0.35s keeps sustained paging safely below that.
  MIN_REQUEST_INTERVAL = 0.35
  MAX_OPERATION_PAGES = 500
  INSTRUMENT_CACHE_TTL = 24.hours
  RETRYABLE_STATUSES = [ 429, 500, 502, 503, 504 ].freeze

  BEARER_REGEX = /(Bearer\s+)[A-Za-z0-9._\-+\/=]+/i

  InstrumentMeta = Data.define(
    :uid,
    :figi,
    :ticker,
    :name,
    :instrument_type,
    :currency,
    :exchange_operating_mic,
    :country_code,
    :nominal,
    :initial_nominal,
    :amortization_flag,
    :logo_url
  )

  attr_reader :environment, :base_url

  def initialize(api_key:, environment: :live, base_url: nil)
    raise ConfigurationError, "T-Invest API token is required" if api_key.blank?

    @api_key = api_key.to_s.strip # pipelock:ignore
    @environment = environment.to_s == "sandbox" ? "sandbox" : "live"
    @base_url = resolve_base_url(base_url)
    @instrument_cache = {}
  end

  def fetch_accounts
    body = post("UsersService", "GetAccounts", { status: "ACCOUNT_STATUS_OPEN" })
    Array(body["accounts"])
  end

  def fetch_portfolio(account_id, currency: "RUB")
    post(
      "OperationsService",
      "GetPortfolio",
      { accountId: account_id.to_s, currency: currency.to_s.upcase }
    )
  end

  # Pages through OperationsService/GetOperationsByCursor using hasNext/nextCursor.
  # Returns { items: Array<Hash>, next_cursor: String|nil }.
  def fetch_operations(account_id, cursor: nil, from: nil, to: nil, limit: 1000, state: "OPERATION_STATE_EXECUTED")
    items = []
    current_cursor = cursor.presence
    seen_cursors = Set.new
    last_next_cursor = nil

    MAX_OPERATION_PAGES.times do
      payload = {
        accountId: account_id.to_s,
        limit: limit,
        state: state,
        withoutCommissions: false,
        withoutTrades: false,
        withoutOvernights: false
      }
      payload[:from] = from.iso8601 if from.respond_to?(:iso8601)
      payload[:from] = from.to_s if from.is_a?(String) && from.present?
      payload[:to] = to.iso8601 if to.respond_to?(:iso8601)
      payload[:to] = to.to_s if to.is_a?(String) && to.present?
      payload[:cursor] = current_cursor if current_cursor.present?

      resp = post("OperationsService", "GetOperationsByCursor", payload)
      page_items = Array(resp["items"])
      items.concat(page_items)

      has_next = resp["hasNext"] == true
      next_cursor = resp["nextCursor"].presence
      last_next_cursor = next_cursor if next_cursor

      break unless has_next && next_cursor
      raise Error, "Pagination loop detected for account #{account_id}: repeated cursor" if seen_cursors.include?(next_cursor)

      seen_cursors.add(next_cursor)
      current_cursor = next_cursor
    end

    newest_cursor = items.first&.dig("cursor").presence || last_next_cursor
    { items: items, next_cursor: newest_cursor }
  end

  def get_instrument_by(identifier, id_type: "INSTRUMENT_ID_TYPE_UID")
    resp = post(
      "InstrumentsService",
      "GetInstrumentBy",
      { idType: id_type, id: identifier.to_s }
    )
    resp["instrument"] || {}
  end

  def get_bond_by(identifier, id_type: "INSTRUMENT_ID_TYPE_UID")
    resp = post(
      "InstrumentsService",
      "BondBy",
      { idType: id_type, id: identifier.to_s }
    )
    resp["instrument"] || {}
  end

  def find_instrument(query)
    q = Provider::TinkoffInvest.strip_exchange_suffix(query)
    return [] if q.blank?

    resp = post("InstrumentsService", "FindInstrument", { query: q })
    Array(resp["instruments"])
  end

  def resolve_instrument(instrument_uid: nil, figi: nil, ticker_hint: nil, instrument_type_hint: nil, name_hint: nil, currency_hint: nil)
    uid_key = instrument_uid.presence
    figi_key = figi.presence

    [ uid_key, figi_key ].compact.each do |key|
      return @instrument_cache[key] if @instrument_cache.key?(key)
    end

    raw = lookup_instrument_raw(uid_key, figi_key, ticker_hint)
    ticker = (raw["ticker"].presence || ticker_hint.presence || figi_key || uid_key).to_s.strip.upcase
    return nil if ticker.blank?

    itype = (raw["instrumentType"].presence || raw["instrumentKind"].presence || instrument_type_hint).to_s.downcase.delete_prefix("instrument_type_")
    name = (raw["name"].presence || name_hint.presence || ticker).to_s.strip
    currency = (raw["currency"].presence || currency_hint.presence || "RUB").to_s.strip.upcase
    mic = Provider::TinkoffInvest.mic_for(raw["classCode"], raw["exchange"])
    country = raw["countryOfRisk"].to_s.strip.upcase.presence
    resolved_uid = raw["uid"].presence || uid_key
    resolved_figi = raw["figi"].presence || figi_key
    logo_url = Provider::TinkoffInvest.logo_url_for(raw.dig("brand", "logoName"))

    nominal, initial_nominal, amort_flag = fetch_bond_metadata(itype, resolved_uid, resolved_figi, currency)

    meta = InstrumentMeta.new(
      uid: resolved_uid,
      figi: resolved_figi,
      ticker: ticker,
      name: name,
      instrument_type: itype,
      currency: currency,
      exchange_operating_mic: mic,
      country_code: country,
      nominal: nominal,
      initial_nominal: initial_nominal,
      amortization_flag: amort_flag,
      logo_url: logo_url
    )

    [ resolved_uid, resolved_figi, uid_key, figi_key ].compact.uniq.each do |key|
      @instrument_cache[key] = meta
    end

    meta
  end

  private

    attr_reader :api_key

    def resolve_base_url(explicit_base_url)
      candidate = explicit_base_url.to_s.strip.presence ||
        ENV["TINKOFF_INVEST_URL"].to_s.strip.presence ||
        (environment == "sandbox" ? SANDBOX_BASE_URL : LIVE_BASE_URL)
      candidate.sub(%r{/+\z}, "")
    end

    def post(service, method, body)
      response = connection.post("#{base_url}/#{Provider::TinkoffInvest::API_NS}.#{service}/#{method}") do |req|
        req.body = body.to_json
      end
      handle_response(response, service, method)
    rescue Faraday::TooManyRequestsError => e
      raise RateLimitError, "T-Invest rate limit exceeded on #{service}/#{method}: #{redact_secret(e.message)}"
    rescue Faraday::Error => e
      raise ApiError.new(
        "T-Invest request error on #{service}/#{method}: #{redact_secret(e.message)}",
        status_code: e.response&.dig(:status),
        response_body: redact_secret(e.response&.dig(:body).to_s.first(400))
      )
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20

        faraday.request :retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          methods: Faraday::Retry::Middleware::IDEMPOTENT_METHODS + [ :post ],
          retry_statuses: RETRYABLE_STATUSES,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        }

        faraday.use Provider::RateLimitable::BeforeEachAttempt, ->(_env) { throttle_request }

        faraday.headers["Authorization"] = "Bearer #{api_key}"
        faraday.headers["Content-Type"] = "application/json"
        faraday.headers["Accept"] = "application/json"
      end
    end

    def handle_response(response, service, method)
      status = response.status.to_i
      safe_body = redact_secret(response.body.to_s.first(400))

      case status
      when 200
        return {} if response.body.blank?

        parsed = JSON.parse(response.body)
        return parsed if parsed.is_a?(Hash)

        raise ApiError.new("T-Invest returned unexpected payload on #{service}/#{method}", status_code: status, response_body: safe_body)
      when 401, 403
        raise AuthenticationError, "T-Invest authentication failed (HTTP #{status}) on #{service}/#{method}: #{safe_body}"
      when 429
        raise RateLimitError, "T-Invest rate limit exceeded (HTTP 429) on #{service}/#{method}: #{safe_body}"
      else
        raise ApiError.new(
          "T-Invest HTTP #{status} on #{service}/#{method}: #{safe_body}",
          status_code: status,
          response_body: safe_body
        )
      end
    rescue JSON::ParserError
      raise ApiError.new(
        "T-Invest returned invalid JSON on #{service}/#{method}",
        status_code: status,
        response_body: safe_body
      )
    end

    def lookup_instrument_raw(uid, figi, ticker_hint)
      id_val = uid || figi
      id_type = uid ? "INSTRUMENT_ID_TYPE_UID" : "INSTRUMENT_ID_TYPE_FIGI"

      if id_val
        cached = Rails.cache.fetch("tinkoff_invest_portfolio:instrument:#{id_type}:#{id_val}", expires_in: INSTRUMENT_CACHE_TTL, skip_nil: true) do
          get_instrument_by(id_val, id_type: id_type).presence
        end
        return cached if cached.present?
      end

      if ticker_hint.present?
        matches = find_instrument(ticker_hint)
        up = ticker_hint.to_s.strip.upcase
        exact = matches.select { |m| m["ticker"].to_s.upcase == up }
        return (exact.presence || matches).first || {}
      end

      {}
    rescue AuthenticationError, RateLimitError
      raise
    rescue Error
      {}
    end

    def fetch_bond_metadata(instrument_type, uid, figi, currency)
      return [ nil, nil, false ] unless instrument_type == "bond" && (uid || figi)

      bond_id = uid || figi
      id_type = uid ? "INSTRUMENT_ID_TYPE_UID" : "INSTRUMENT_ID_TYPE_FIGI"

      bond_raw = Rails.cache.fetch("tinkoff_invest_portfolio:bond:#{id_type}:#{bond_id}", expires_in: INSTRUMENT_CACHE_TTL, skip_nil: true) do
        get_bond_by(bond_id, id_type: id_type).presence
      end
      return [ nil, nil, false ] if bond_raw.blank?

      nominal, = Provider::TinkoffInvest.money_to_decimal_and_currency(bond_raw["nominal"], currency)
      initial_nominal, = Provider::TinkoffInvest.money_to_decimal_and_currency(bond_raw["initialNominal"], currency)
      amort_flag = bond_raw["amortizationFlag"] == true
      [ nominal, initial_nominal, amort_flag ]
    rescue AuthenticationError, RateLimitError
      raise
    rescue Error
      [ nil, nil, false ]
    end

    def redact_secret(text)
      return "" if text.blank?

      cleaned = text.to_s.gsub(BEARER_REGEX, '\1[REDACTED]')
      cleaned = cleaned.gsub(api_key, "[REDACTED]") if api_key.present?
      cleaned
    end
end
