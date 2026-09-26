require "base64"
require "cgi"
require "json"
require "bigdecimal"
require "set"
require "time"

class Provider::TradeRepublicClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationRequired < Error; end
  class LoginExpired < Error; end
  class InvalidChallenge < Error; end
  class ProviderUnavailable < Error; end
  class TransientProviderError < ProviderUnavailable; end
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      @retry_after = retry_after
      super(message)
    end
  end
  class WafRequired < Error; end
  class Timeout < Error; end
  class MalformedResponse < Error; end

  ERROR_STATUS = {
    401 => AuthenticationRequired,
    403 => AuthenticationRequired,
    408 => Timeout,
    429 => RateLimited,
    500 => TransientProviderError,
    502 => TransientProviderError,
    503 => TransientProviderError,
    504 => TransientProviderError
  }.freeze
  # Categories/event types that need timelineDetailV2 for ISIN and quantity.
  # Ordinary cash movements (card payments, transfers, interest, dividends) use
  # the timeline list amount only and must not consume the detail budget.
  TRADE_DETAIL_CATEGORY = "orderExecution"
  TRADE_DETAIL_EVENT_TYPES = %w[
    SAVEBACK_AGGREGATE
    SPARE_CHANGE_AGGREGATE
  ].freeze
  EVENT_TYPE_CATEGORIES = Provider::TradeRepublicTimelineEvent::EVENT_TYPE_CATEGORIES
  PORTFOLIO_CATEGORIES = {
    "stocksAndETFs" => "brokerage",
    "privateMarkets" => "private_markets",
    "interest" => "interest_products",
    "bonds" => "interest_products",
    "cryptos" => "crypto_wallet"
  }.freeze
  TICKER_EXCHANGES = %w[LSX BHS TUB SGL BVT].freeze
  CRYPTO_TICKER_EXCHANGES = %w[BHS TUB SGL BVT LSX].freeze
  # Prefer real venues over Trade Republic's synthetic LSX feed. Skip symbols
  # that merely echo the ISIN (common on TIB).
  INSTRUMENT_EXCHANGE_PREFERENCE = %w[XETR TDG].freeze
  INSTRUMENT_EXCHANGE_LAST_RESORT = %w[LSX].freeze
  INSTRUMENT_SYMBOL_CATEGORIES = %w[stocksAndETFs bonds].freeze
  FEE_TITLES = [
    "gebühr", "fee", "fees", "kosten", "costs", "cost", "commission", "kommission"
  ].freeze
  TAX_TITLES = [ "steuer", "steuern", "tax", "taxes", "belasting" ].freeze
  SHARE_TITLES = [
    "aktien", "anteile", "shares", "aandelen",
    "aktien hinzugefügt", "shares added", "aktien erhalten", "shares received",
    "aktien entfernt", "shares removed", "aktien gesendet", "shares sent"
  ].freeze
  TOTAL_TITLES = [ "gesamt", "total", "totaal", "gesamtbetrag" ].freeze
  PRICE_TITLES = [
    "share price", "aandelenkoers", "aktienkurs", "anteilskurs",
    "execution price", "kurs"
  ].freeze
  SELL_SUBTITLE_MARKERS = %w[sell verkauf verkaufen verkopen].freeze
  MAX_TIMELINE_PAGES = 50
  MAX_TIMELINE_DETAILS = 200
  # Reserve this many detail fetches for newly discovered trade events each
  # sync. The remainder drains the oldest stored incomplete events; leftover
  # budget returns to additional new events.
  MAX_TIMELINE_DETAILS_DELTA_RESERVED = 50
  # Cap instrument lookups for sold / historical trade ISINs that are absent
  # from the current portfolio snapshot.
  MAX_INSTRUMENT_LOOKUPS = 100
  MAX_SYNC_RETRIES = 2
  RETRY_BACKOFF_SECONDS = 0.5
  LOGIN_SUCCESS_STATES = %w[CONFIRMED COMPLETED APPROVED SUCCESS OK DONE].freeze
  CONNECT_MESSAGE = { locale: "en", platformId: "webtrading", platformVersion: "chrome - 94.0.4606", clientId: "app.traderepublic.com", clientVersion: "5582" }.freeze

  Result = Struct.new(:data, keyword_init: true) do
    def [](key) = data[key]
  end

  attr_reader :phone_number, :pin

  def initialize(phone_number:, pin: nil)
    @phone_number = phone_number.to_s.strip
    @pin = pin.to_s
  end

  def initiate_login
    require_pin!
    session = new_session
    response = session.post("/api/v2/auth/web/login", body: { phoneNumber: phone_number, pin: pin }, headers: session.login_headers)
    raise_http_error(response)
    body = parse_json(response)
    process_id = body["processId"].presence
    raise MalformedResponse, "Trade Republic login response did not contain a process ID" if process_id.blank?

    process_response = session.get("/api/v2/auth/web/login/processes/#{escape_path(process_id)}", headers: session.login_headers)
    raise_http_error(process_response, login: true)
    required_action = parse_json(process_response)["requiredAction"]
    countdown_seconds = body.fetch("countdownInSeconds", 120).to_i.clamp(1, 120)
    pending = {
      "process_id" => process_id,
      "required_action" => required_action,
      "session_blob" => session.cookies_blob,
      "expires_at" => countdown_seconds.seconds.from_now.iso8601
    }

    Result.new(data: {
      "status" => "verification_required",
      "method" => required_action == "AUTHENTICATOR_VERIFICATION" ? "authenticator" : "push",
      "countdown_seconds" => countdown_seconds,
      "pending_login_b64" => Base64.strict_encode64(JSON.generate(pending))
    })
  rescue Net::HTTPClientException => e
    raise_login_error(e.response)
  end

  # Starts the browser QR login without blocking while the user scans and
  # approves the challenge in the Trade Republic app.
  def initiate_qr_login
    session = new_session
    response = session.post("/api/v2/auth/web/login/qr-challenges", body: nil, headers: session.login_headers)
    raise_http_error(response, login: true)
    body = parse_json(response)
    challenge_id = body["challengeId"].presence
    raise MalformedResponse, "Trade Republic QR login response did not contain a challenge ID" if challenge_id.blank?

    pending = {
      "challenge_id" => challenge_id,
      "session_blob" => session.cookies_blob,
      "expires_at" => body["challengeExpiresAt"].presence || 120.seconds.from_now.iso8601,
      "qr_code_payload" => body["qrCodePayload"].presence,
      "qr_code_token_expires_at" => body["qrCodeTokenExpiresAt"].presence
    }
    Result.new(data: {
      "status" => "qr_pending",
      "pending_login_b64" => encode_pending(pending),
      "expires_at" => pending["expires_at"],
      "qr_code_payload" => pending["qr_code_payload"],
      "qr_code_token_expires_at" => pending["qr_code_token_expires_at"]
    })
  rescue Net::HTTPClientException => e
    raise_login_error(e.response)
  end

  def poll_qr_login(pending_login_b64:)
    pending = decode_qr_pending(pending_login_b64)
    session = new_session(session_blob: pending.fetch("session_blob"))
    challenge_response = session.get(
      "/api/v2/auth/web/login/qr-challenges/#{escape_path(pending.fetch("challenge_id"))}",
      headers: session.login_headers
    )
    raise_http_error(challenge_response, login: true)
    challenge = parse_json(challenge_response)
    process_id = challenge["processId"].presence

    if process_id.blank? && login_process_completed?(challenge)
      return authenticated_session_result(session)
    end

    unless process_id
      qr_code_payload = challenge["qrCodePayload"].presence || pending["qr_code_payload"]
      next_pending = pending.merge(
        "qr_code_payload" => qr_code_payload,
        "qr_code_token_expires_at" => challenge["qrCodeTokenExpiresAt"].presence || pending["qr_code_token_expires_at"]
      )
      return Result.new(data: {
        "status" => "pending",
        "qr_code_payload" => qr_code_payload,
        "qr_code_token_expires_at" => next_pending["qr_code_token_expires_at"],
        "pending_login_b64" => encode_pending(next_pending)
      }.compact)
    end

    process_response = session.get(
      "/api/v2/auth/web/login/processes/#{escape_path(process_id)}",
      headers: session.login_headers
    )
    raise_http_error(process_response, login: true)
    process = parse_json(process_response)
    unless login_process_completed?(process)
      return Result.new(data: {
        "status" => "pending",
        "process_id" => process_id,
        "pending_login_b64" => encode_pending(pending.merge("process_id" => process_id))
      })
    end

    authenticated_session_result(session)
  rescue Net::HTTPClientException => e
    raise_login_error(e.response)
  end

  def complete_login(pending_login_b64:, code: nil)
    pending = decode_pending(pending_login_b64)
    session = new_session(session_blob: pending.fetch("session_blob"))
    process_id = pending.fetch("process_id")
    headers = session.login_headers

    if pending["required_action"] == "AUTHENTICATOR_VERIFICATION" && !pending["authenticator_verified"]
      raise InvalidChallenge, "Authenticator code is required" if code.blank?
      response = session.post("/api/v2/auth/web/login/processes/#{escape_path(process_id)}/authenticator-verification", body: { code: code }, headers: headers)
      raise_http_error(response, login: true)
      pending["authenticator_verified"] = true
    end

    process_response = session.get("/api/v2/auth/web/login/processes/#{escape_path(process_id)}", headers: headers)
    raise_http_error(process_response, login: true)
    process = parse_json(process_response)
    unless login_process_completed?(process)
      return Result.new(data: {
        "status" => "pending",
        "pending_login_b64" => Base64.strict_encode64(JSON.generate(pending))
      })
    end

    authenticated_session_result(session)
  rescue KeyError, ArgumentError => e
    raise InvalidChallenge, "Trade Republic login state is invalid: #{e.message}"
  rescue Net::HTTPClientException => e
    raise_login_error(e.response)
  end

  def login_method(pending_login_b64:)
    pending = decode_pending(pending_login_b64)
    pending["required_action"] == "AUTHENTICATOR_VERIFICATION" ? "authenticator" : "push"
  end

  def qr_login?(pending_login_b64:)
    pending = JSON.parse(Base64.strict_decode64(pending_login_b64.to_s))
    pending["challenge_id"].present?
  rescue JSON::ParserError, ArgumentError
    false
  end

  def login_stage(pending_login_b64:)
    return "qr_pending" if qr_login?(pending_login_b64: pending_login_b64)

    pending = decode_pending(pending_login_b64)
    if pending["required_action"] == "AUTHENTICATOR_VERIFICATION" && !pending["authenticator_verified"]
      "authenticator_code"
    else
      "waiting_for_approval"
    end
  end

  def sync(session_txt:, known_newest_event_id: nil, timeline_max_pages: MAX_TIMELINE_PAGES, enrich_events: [], symbol_lookup_isins: [])
    raise ConfigurationError, "session_txt is required" if session_txt.blank?

    with_retry do
      sync_once(
        session_txt: session_txt,
        known_newest_event_id: known_newest_event_id,
        timeline_max_pages: timeline_max_pages,
        enrich_events: enrich_events,
        symbol_lookup_isins: symbol_lookup_isins
      )
    end
  end

  def sync_once(session_txt:, known_newest_event_id:, timeline_max_pages:, enrich_events: [], symbol_lookup_isins: [])
    session = new_session(session_blob: session_txt)
    account_response = session.get("/api/v2/auth/account")
    return Result.new(data: { "status" => "session_expired" }) if [ 401, 403 ].include?(account_response.code.to_i)
    raise_http_error(account_response)
    account = parse_json(account_response)
    raise MalformedResponse, "Trade Republic account response did not contain a securities account number" if account["securitiesAccountNumber"].blank?
    warnings = []
    domain_statuses = {
      "account_metadata" => "success",
      "cash" => "failed",
      "portfolio" => "failed",
      "timeline" => "failed",
      "instrument_metadata" => "failed"
    }
    websocket = Provider::TradeRepublicWebsocket.new(headers: session.websocket_headers).connect

    begin
      websocket.send_text("connect 31 #{JSON.generate(CONNECT_MESSAGE)}")
      connected = websocket.receive
      raise TransientProviderError, "Trade Republic WebSocket handshake was rejected" unless connected == "connected"

      cash = available_cash = nil
      begin
        cash = subscribe(websocket, type: "cash")
        available_cash = optional_subscribe(websocket, type: "availableCash")
        raise MalformedResponse, "Trade Republic cash response did not contain an amount" if money_amount(cash).nil?
        domain_statuses["cash"] = "success"
      rescue MalformedResponse, ProviderUnavailable => e
        raise if e.is_a?(TransientProviderError)
        warnings << "cash fetch failed: #{e.message}"
      end

      positions = []
      position_warnings = []
      begin
        portfolio = subscribe(websocket, type: "compactPortfolioByType", secAccNo: account["securitiesAccountNumber"])
        raise MalformedResponse, "Trade Republic portfolio response did not contain categories" unless portfolio.is_a?(Hash) && portfolio.key?("categories")
        positions, position_warnings = normalize_positions(
          websocket,
          portfolio,
          sec_acc_no: account["securitiesAccountNumber"]
        )
        warnings.concat(position_warnings)
        domain_statuses["portfolio"] = "success"
        domain_statuses["instrument_metadata"] = position_warnings.empty? ? "success" : "partial"
      rescue MalformedResponse, ProviderUnavailable => e
        raise if e.is_a?(TransientProviderError)
        warnings << "portfolio fetch failed: #{e.message}"
      end

      known_symbols = instrument_symbols_from_positions(positions)
      instrument_symbols = known_symbols.dup

      events = []
      newest_event_id = nil
      timeline_warnings = []
      timeline_complete = false
      detail_backfill_count = 0
      begin
        events, newest_event_id, timeline_warnings, timeline_complete, detail_backfill_count = collect_all_timeline(
          websocket,
          known_newest_event_id: known_newest_event_id,
          max_pages: timeline_max_pages.to_i,
          enrich_events: enrich_events
        )
        instrument_symbols = enrich_trade_instrument_symbols(
          websocket,
          events,
          known_symbols: known_symbols,
          extra_isins: symbol_lookup_isins
        )
        warnings.concat(timeline_warnings)
        # Timeline domain reflects list pagination only. Detail backlog drains
        # across later syncs and must not freeze newest_event_id.
        domain_statuses["timeline"] = timeline_complete ? "success" : "partial"
      rescue MalformedResponse, ProviderUnavailable => e
        raise if e.is_a?(TransientProviderError)
        warnings << "timeline fetch failed: #{e.message}"
      end

      Result.new(data: {
        "status" => domain_statuses.values.all? { |status| status == "success" } ? "ok" : "partial",
        "session_txt" => session.cookies_blob,
        "domain_statuses" => domain_statuses,
        "account" => { "brokerage_account_id" => account["securitiesAccountNumber"].to_s, "currency" => account["currency"] },
        "cash" => (cash && {
          "amount" => decimal_string(money_amount(cash)),
          "available_amount" => decimal_string(money_amount(available_cash)),
          "currency" => money_currency(available_cash) || money_currency(cash)
        }.compact),
        "positions" => positions,
        "events" => events,
        "instrument_symbols" => instrument_symbols,
        "newest_event_id" => newest_event_id,
        "timeline_pagination_complete" => timeline_complete,
        "detail_backfill_count" => detail_backfill_count,
        "warnings" => warnings,
        "position_warnings" => position_warnings
      })
    ensure
      websocket.close
    end
  rescue Provider::TradeRepublicClient::Timeout
    raise Timeout, "Trade Republic WebSocket timed out"
  end

  class << self
    def available? = !!defined?(WebSocket::Driver)

    def requires_trade_detail?(item)
      return false unless item.is_a?(Hash)

      item = item.stringify_keys
      category = item["category"].presence || EVENT_TYPE_CATEGORIES[item["eventType"].to_s]
      return true if category.to_s == TRADE_DETAIL_CATEGORY

      TRADE_DETAIL_EVENT_TYPES.include?(item["eventType"].to_s)
    end

    def trade_detail_complete?(event)
      return false unless event.is_a?(Hash)

      detail = event["detail"] || event[:detail]
      return false unless detail.is_a?(Hash)

      detail = detail.stringify_keys
      detail["isin"].present? && detail["quantity"].present?
    end

    def incomplete_trade_detail_event?(event)
      return false unless requires_trade_detail?(event)
      return false unless Provider::TradeRepublicTimelineEvent.importable?(event)

      !trade_detail_complete?(event)
    end

    # Complete trades (isin + quantity) that still lack a share price — usually
    # stored before we parsed execution price / fees from timeline details.
    def trade_detail_needs_price_backfill?(event)
      return false unless requires_trade_detail?(event)
      return false unless Provider::TradeRepublicTimelineEvent.importable?(event)
      return false unless trade_detail_complete?(event)

      detail = (event["detail"] || event[:detail]).stringify_keys
      detail["price"].to_s.strip.blank?
    end
  end

  private

    def with_retry
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Timeout, RateLimited, TransientProviderError => e
        raise if attempts > MAX_SYNC_RETRIES

        delay = if e.is_a?(RateLimited) && e.retry_after.present?
          e.retry_after
        else
          RETRY_BACKOFF_SECONDS * (2**(attempts - 1))
        end
        sleep_for([ delay.to_f, 30.0 ].min)
        retry
      end
    end

    def sleep_for(seconds)
      sleep(seconds)
    end

    def new_session(session_blob: nil)
      Provider::TradeRepublicSession.new(phone_number: phone_number, pin: pin, session_blob: session_blob)
    end

    def require_pin!
      raise ConfigurationError, "Trade Republic PIN is required for authentication" if pin.blank?
    end

    def decode_pending(value)
      pending = JSON.parse(Base64.strict_decode64(value.to_s))
      raise ArgumentError, "missing login process" unless pending["process_id"].present?
      raise ArgumentError, "missing login session" unless pending["session_blob"].present?
      raise LoginExpired, "Trade Republic login process expired" if pending["expires_at"].present? && Time.iso8601(pending["expires_at"]) <= Time.current
      pending
    rescue JSON::ParserError, ArgumentError => e
      raise InvalidChallenge, "Trade Republic login state is unreadable: #{e.message}"
    end

    def decode_qr_pending(value)
      pending = JSON.parse(Base64.strict_decode64(value.to_s))
      raise ArgumentError, "missing QR challenge" unless pending["challenge_id"].present?
      raise ArgumentError, "missing login session" unless pending["session_blob"].present?
      expires_at = pending["expires_at"].presence
      raise LoginExpired, "Trade Republic QR login expired" if expires_at && Time.iso8601(expires_at) <= Time.current
      pending
    rescue JSON::ParserError, ArgumentError => e
      raise InvalidChallenge, "Trade Republic QR login state is unreadable: #{e.message}"
    end

    def encode_pending(pending)
      Base64.strict_encode64(JSON.generate(pending))
    end

    def login_process_completed?(process)
      %w[state status statusCode result].any? do |key|
        LOGIN_SUCCESS_STATES.include?(process[key].to_s.upcase)
      end
    end

    def authenticated_session_result(session)
      account_response = session.get("/api/v2/auth/account", headers: session.login_headers)
      raise_http_error(account_response, login: true)
      account = parse_json(account_response)
      if account["securitiesAccountNumber"].blank?
        raise MalformedResponse, "Trade Republic account response did not contain a securities account number"
      end

      Result.new(data: {
        "status" => "ok",
        "session_txt" => session.cookies_blob,
        "account" => {
          "brokerage_account_id" => account["securitiesAccountNumber"].to_s,
          "currency" => account["currency"]
        }
      })
    end

    def escape_path(value) = CGI.escape(value.to_s).tr("+", "%20")

    def parse_json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      raise MalformedResponse, "Trade Republic returned invalid JSON: #{e.message}"
    end

    def raise_http_error(response, login: false)
      return if response.is_a?(Net::HTTPSuccess)
      error_code = response_error_code(response)
      if error_code.to_s.match?(/WAF|MISSING_REQUIRED_HEADER/)
        raise WafRequired, "Trade Republic requires an AWS WAF browser token"
      end
      raise_login_error(response) if login
      message = "Trade Republic request failed with HTTP #{response.code}"
      message += " (#{error_code})" if error_code.present?
      error_class = ERROR_STATUS.fetch(response.code.to_i, ProviderUnavailable)
      if error_class == RateLimited
        raise RateLimited.new(message, retry_after: retry_after_seconds(response))
      end

      raise error_class, message
    end

    def retry_after_seconds(response)
      value = response["Retry-After"].to_s
      return value.to_f if value.match?(/\A\d+(?:\.\d+)?\z/)

      return if value.blank?

      [ Time.httpdate(value) - Time.current, 0 ].max
    rescue ArgumentError
      nil
    end

    def raise_login_error(response)
      return if response.is_a?(Net::HTTPSuccess)
      code = begin
        response_error_code(response)
      rescue MalformedResponse
        nil
      end
      raise LoginExpired, "Trade Republic login process expired" if response.code.to_i == 404
      if response.code.to_i == 409 && code.to_s == "ALREADY_PROCESSED"
        raise LoginExpired, "Trade Republic QR login token expired or was already used"
      end
      raise InvalidChallenge, "Trade Republic rejected the authenticator code" if code.to_s.match?(/CODE|AUTHENTICATOR|VERIFICATION/)
      raise ERROR_STATUS.fetch(response.code.to_i, ProviderUnavailable), "Trade Republic login failed"
    end

    def response_error_code(response)
      body = parse_json(response)
      body["errorCode"].presence || body.dig("errors", 0, "errorCode").presence
    rescue MalformedResponse
      nil
    end

    def subscribe(websocket, payload)
      @subscription_id = @subscription_id.to_i + 1
      websocket.send_text("sub #{@subscription_id} #{JSON.generate(payload)}")
      receive_subscription(websocket, @subscription_id)
    ensure
      begin
        websocket.send_text("unsub #{@subscription_id}") if @subscription_id
      rescue IOError, ProviderUnavailable
        nil
      end
    end

    def optional_subscribe(websocket, payload)
      subscribe(websocket, payload)
    rescue TransientProviderError
      raise
    rescue Error
      nil
    end

    def receive_subscription(websocket, subscription_id)
      previous = nil
      loop do
        message = websocket.receive.to_s
        id, code, payload = message.split(" ", 3)
        next unless id.to_s == subscription_id.to_s
        case code
        when "A"
          previous = payload.to_s
          return parse_payload(previous)
        when "D"
          previous = apply_delta(previous, payload.to_s)
          return parse_payload(previous)
        when "E" then raise ProviderUnavailable, "Trade Republic subscription failed"
        when "C" then raise ProviderUnavailable, "Trade Republic closed the subscription"
        end
      end
    end

    def parse_payload(payload)
      JSON.parse(payload.presence || "{}")
    rescue JSON::ParserError => e
      raise MalformedResponse, "Trade Republic WebSocket payload is invalid: #{e.message}"
    end

    def apply_delta(previous, delta)
      raise MalformedResponse, "Trade Republic sent a delta without a base response" if previous.blank?
      index = 0
      delta.split("\t").filter_map do |diff|
        sign = diff[0]
        case sign
        when "+" then CGI.unescape(diff).strip
        when "="
          length = diff[1..].to_i
          fragment = previous[index, length]
          index += length
          fragment
        when "-"
          index += diff[1..].to_i
          nil
        end
      end.join
    end

    def normalize_positions(websocket, portfolio, sec_acc_no: nil)
      raw_positions = Array(portfolio["categories"]).flat_map do |category|
        Array(category["positions"]).map { |position| position.merge("categoryType" => category["categoryType"]) }
      end
      warnings = []
      valid_positions = raw_positions.select do |position|
        isin = position["instrumentId"].presence || position["isin"]
        quantity = position["netSize"] || position["quantity"]
        if isin.blank? || quantity.blank?
          warnings << "malformed portfolio position skipped: missing #{isin.blank? ? "instrument ID" : "quantity"}"
          false
        else
          true
        end
      end
      prices = {}
      price_sources = {}
      instruments = {}
      private_market_quotes = private_markets_unit_prices(websocket, sec_acc_no) if valid_positions.any? { |p|
        p["categoryType"].to_s == "privateMarkets"
      }

      valid_positions.each do |position|
        isin = position["instrumentId"].presence || position["isin"]
        next if prices.key?(isin)

        price = position_price(websocket, isin, position["categoryType"])
        price_source = nil

        if price.blank? && private_market_quotes.present?
          price = private_market_quotes[isin]
          price_source = "private_markets" if price.present?
        end

        if price.blank?
          cost = decimal_string(position["averageBuyIn"] || position["avgCost"])
          if cost.present?
            price = cost
            price_source = "cost_basis"
          else
            warnings << "price unavailable for #{isin}; position kept without valuation"
          end
        end

        if price.present?
          prices[isin] = price
          price_sources[isin] = price_source if price_source.present?
        end
      end
      valid_positions.each do |position|
        isin = position["instrumentId"].presence || position["isin"]
        next if instruments.key?(isin)
        next unless INSTRUMENT_SYMBOL_CATEGORIES.include?(position["categoryType"].to_s)

        instruments[isin] = instrument_exchange_symbol(websocket, isin)
      end

      positions = valid_positions.map do |position|
        isin = position["instrumentId"].presence || position["isin"]
        quantity = position["netSize"] || position["quantity"]
        instrument = instruments[isin] || {}
        {
          "isin" => isin,
          "name" => position["name"],
          "category" => portfolio_category(position["categoryType"]),
          "quantity" => decimal_string(quantity),
          "average_cost" => decimal_string(position["averageBuyIn"] || position["avgCost"]),
          "price" => prices[isin],
          "price_source" => price_sources[isin],
          "symbol" => instrument[:symbol],
          "exchange_slug" => instrument[:exchange_slug]
        }.compact
      end
      [ positions, warnings ]
    end

    def position_price(websocket, isin, category_type)
      home_exchange = home_instrument_exchange_id(websocket, isin)
      if home_exchange.present?
        price = ticker_last_price(websocket, isin, home_exchange)
        return price if price.present?
      end

      exchanges = category_type.to_s == "cryptos" ? CRYPTO_TICKER_EXCHANGES : TICKER_EXCHANGES
      exchanges.each do |exchange|
        next if exchange == home_exchange

        price = ticker_last_price(websocket, isin, exchange)
        return price if price.present?
      end

      nil
    end

    def home_instrument_exchange_id(websocket, isin)
      home = optional_subscribe(websocket, type: "homeInstrumentExchange", id: isin)
      return nil unless home.is_a?(Hash)

      (home["exchangeId"].presence || home["id"].presence || home["slug"].presence).to_s.strip.upcase.presence
    rescue Error
      nil
    end

    def ticker_last_price(websocket, isin, exchange)
      ticker = subscribe(websocket, type: "ticker", id: "#{isin}.#{exchange}")
      price = ticker.dig("last", "price") if ticker.is_a?(Hash)
      decimal_string(price) if price.present?
    rescue Timeout
      # A hung ticker feed must not block the rest of the exchange list or the
      # private-markets / cost-basis fallbacks below.
      nil
    rescue TransientProviderError, RateLimited
      raise
    rescue Error
      nil
    end

    # Best-effort PE enrichment. Trade Republic rejects the subscription when
    # the account has no private-markets sleeve — treat that as an empty map.
    def private_markets_unit_prices(websocket, sec_acc_no)
      return {} if sec_acc_no.blank?

      payload = optional_subscribe(websocket, type: "privateMarketsPositions", secAccNo: sec_acc_no)
      return {} unless payload.is_a?(Hash)

      Array(payload["positions"]).each_with_object({}) do |position, prices|
        next unless position.is_a?(Hash)

        isin = position["instrumentId"].presence || position["isin"]
        next if isin.blank?

        unit_price = private_markets_unit_price(position)
        prices[isin] = unit_price if unit_price.present?
      end
    rescue Error
      {}
    end

    def private_markets_unit_price(position)
      quantity = decimal_string(position["netSize"] || position["quantity"] || position["size"])
      qty = quantity.present? ? BigDecimal(quantity) : nil

      explicit = decimal_string(
        position["unitPrice"] ||
        position["nav"] ||
        position["price"] ||
        position.dig("positionReturn", "price") ||
        position.dig("positionReturn", "unitPrice") ||
        position.dig("quotation", "price")
      )
      return explicit if explicit.present?

      total = money_amount(
        position["positionReturn"] ||
        position["currentValue"] ||
        position["marketValue"] ||
        position["netValue"] ||
        position["value"]
      )
      total_s = decimal_string(total)
      return nil if total_s.blank? || qty.nil? || qty.zero?

      decimal_string(BigDecimal(total_s) / qty)
    rescue ArgumentError
      nil
    end

    # Returns { symbol:, exchange_slug: } from the instrument subscription, or
    # nil when Trade Republic has no usable exchange ticker for this ISIN.
    def instrument_exchange_symbol(websocket, isin)
      payload = optional_subscribe(websocket, type: "instrument", id: isin)
      return nil unless payload.is_a?(Hash)

      pick_instrument_exchange_symbol(payload, isin)
    rescue Error
      nil
    end

    def instrument_symbols_from_positions(positions)
      Array(positions).each_with_object({}) do |position, map|
        next unless position.is_a?(Hash)

        isin = position["isin"].to_s.presence
        symbol = position["symbol"].to_s.strip.presence
        exchange_slug = position["exchange_slug"].to_s.strip.upcase.presence
        next if isin.blank? || symbol.blank? || exchange_slug.blank?
        next if symbol.casecmp?(isin)

        map[isin] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end
    end

    # Look up exchange tickers for trade ISINs that are no longer (or never)
    # present in the current portfolio snapshot — e.g. fully sold holdings.
    # `extra_isins` covers stored timeline trades that incremental syncs no
    # longer re-fetch after the newest-event cursor advances.
    def enrich_trade_instrument_symbols(websocket, events, known_symbols: {}, extra_isins: [])
      symbols = stringify_instrument_symbols(known_symbols)
      missing_isins = (
        trade_isins_missing_symbols(events, symbols) +
        Array(extra_isins).map { |isin| isin.to_s.presence }.compact
      ).uniq
      missing_isins.reject! { |isin| symbols.key?(isin) }

      looked_up = 0
      missing_isins.each do |isin|
        break if looked_up >= MAX_INSTRUMENT_LOOKUPS

        looked_up += 1
        instrument = instrument_exchange_symbol(websocket, isin)
        next unless instrument.is_a?(Hash)

        symbol = instrument[:symbol].to_s.strip.presence
        exchange_slug = instrument[:exchange_slug].to_s.strip.upcase.presence
        next if symbol.blank? || exchange_slug.blank?
        next if symbol.casecmp?(isin)

        symbols[isin] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end

      stamp_instrument_symbols_on_events!(events, symbols)
      symbols
    end

    def trade_isins_missing_symbols(events, known_symbols)
      missing = []
      Array(events).each do |event|
        next unless event.is_a?(Hash)
        next unless self.class.requires_trade_detail?(event)
        next unless Provider::TradeRepublicTimelineEvent.importable?(event)

        detail = event["detail"] || event[:detail]
        next unless detail.is_a?(Hash)

        detail = detail.stringify_keys
        isin = detail["isin"].to_s.presence
        next if isin.blank?
        next if known_symbols.key?(isin)
        next if usable_trade_symbol?(detail["symbol"], isin) && detail["exchange_slug"].to_s.strip.present?

        missing << isin
      end
      missing.uniq
    end

    def stamp_instrument_symbols_on_events!(events, symbols)
      Array(events).each do |event|
        next unless event.is_a?(Hash)

        detail = event["detail"] || event[:detail]
        next unless detail.is_a?(Hash)

        detail = detail.stringify_keys
        isin = detail["isin"].to_s.presence
        next if isin.blank?

        mapping = symbols[isin]
        next unless mapping

        if usable_trade_symbol?(detail["symbol"], isin) && detail["exchange_slug"].to_s.strip.present?
          next
        end

        detail["symbol"] = mapping["symbol"] if detail["symbol"].blank? || !usable_trade_symbol?(detail["symbol"], isin)
        detail["exchange_slug"] = mapping["exchange_slug"] if detail["exchange_slug"].to_s.strip.blank?
        event["detail"] = detail
      end
      events
    end

    def stringify_instrument_symbols(known_symbols)
      Array(known_symbols).each_with_object({}) do |(isin, mapping), map|
        next if isin.blank? || !mapping.is_a?(Hash)

        entry = mapping.stringify_keys
        symbol = entry["symbol"].to_s.strip.presence
        exchange_slug = entry["exchange_slug"].to_s.strip.upcase.presence
        next if symbol.blank? || exchange_slug.blank?
        next if symbol.casecmp?(isin.to_s)

        map[isin.to_s] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end
    end

    def usable_trade_symbol?(symbol, isin)
      candidate = symbol.to_s.strip.presence
      return false if candidate.blank?
      return false if candidate.casecmp?(isin.to_s)

      true
    end

    def pick_instrument_exchange_symbol(payload, isin)
      candidates = Array(payload["exchanges"]).filter_map do |exchange|
        next unless exchange.is_a?(Hash)
        next if exchange.key?("active") && !ActiveModel::Type::Boolean.new.cast(exchange["active"])

        symbol = exchange["symbolAtExchange"].to_s.strip.presence
        next if symbol.blank?
        next if symbol.casecmp?(isin.to_s)

        slug = (exchange["slug"].presence || exchange["exchangeId"].presence || exchange["name"]).to_s.strip.upcase
        next if slug.blank?

        { symbol: symbol, exchange_slug: slug }
      end
      return nil if candidates.empty?

      preferred = INSTRUMENT_EXCHANGE_PREFERENCE.filter_map { |slug| candidates.find { |c| c[:exchange_slug] == slug } }
      return preferred.first if preferred.any?

      non_last_resort = candidates.reject { |c| INSTRUMENT_EXCHANGE_LAST_RESORT.include?(c[:exchange_slug]) }
      return non_last_resort.first if non_last_resort.any?

      candidates.first
    end

    def portfolio_category(category_type)
      PORTFOLIO_CATEGORIES[category_type.to_s] || category_type
    end

    def money_amount(value)
      case value
      when Hash
        direct = value["amount"] || value["value"] || value["balance"] || value["available"]
        return direct if direct.is_a?(Numeric) || direct.to_s.match?(/\A-?[\d.,]+\z/)

        value.each_value do |child|
          amount = money_amount(child)
          return amount if amount.present?
        end
      when Array
        value.each do |child|
          amount = money_amount(child)
          return amount if amount.present?
        end
      end
      nil
    end

    def money_currency(value)
      case value
      when Hash
        return value["currency"] if value["currency"].present?
        value.each_value do |child|
          currency = money_currency(child)
          return currency if currency.present?
        end
      when Array
        value.each do |child|
          currency = money_currency(child)
          return currency if currency.present?
        end
      end
      nil
    end

    def collect_timeline(websocket, known_newest_event_id:, max_pages:)
      collect_timeline_topic(
        websocket,
        topic: "timelineTransactions",
        known_newest_event_id: known_newest_event_id,
        max_pages: max_pages
      )
    end

    def collect_all_timeline(websocket, known_newest_event_id:, max_pages:, enrich_events: [])
      transaction_events, transaction_newest, transaction_warnings, transaction_complete = collect_timeline_topic(
        websocket,
        topic: "timelineTransactions",
        known_newest_event_id: known_newest_event_id,
        max_pages: max_pages
      )
      activity_events, activity_newest, activity_warnings, activity_complete = collect_timeline_topic(
        websocket,
        topic: "timelineActivityLog",
        known_newest_event_id: known_newest_event_id,
        max_pages: max_pages
      )
      skeleton_events = (transaction_events + activity_events).uniq do |event|
        event["id"].presence || event.slice("timestamp", "eventType", "title", "subtitle", "detail")
      end
      events, detail_warnings, detail_backfill_count = enrich_timeline_details(
        websocket,
        skeleton_events,
        enrich_events: enrich_events
      )
      newest_event = events.max_by { |event| event["timestamp"].to_s }
      # Pagination completeness only — pending details drain on later syncs.
      timeline_complete = transaction_complete != false && activity_complete != false
      [
        events,
        newest_event&.dig("id") || transaction_newest || activity_newest,
        transaction_warnings + activity_warnings + detail_warnings,
        timeline_complete,
        detail_backfill_count
      ]
    end

    def collect_timeline_topic(websocket, topic:, known_newest_event_id:, max_pages:)
      items = []
      newest_event_id = nil
      cursor = nil
      warnings = []
      pages = 0
      seen_cursors = Set.new
      reached_known_event = false
      complete = true
      while pages < [ max_pages, MAX_TIMELINE_PAGES ].min
        payload = { type: topic }
        payload[:after] = cursor if cursor
        response = subscribe(websocket, payload)
        page_items = response.is_a?(Hash) ? Array(response["items"]) : []
        break if page_items.empty?
        page_items.each do |item|
          id = item["id"].to_s
          reached_known_event ||= known_newest_event_id.present? && id == known_newest_event_id.to_s
          items << item
          newest_event_id ||= id.presence
        end
        cursor = response.dig("cursors", "after")
        break if cursor.blank?
        if reached_known_event
          break
        end
        if seen_cursors.include?(cursor)
          warnings << "timeline pagination cursor repeated for #{topic}"
          complete = false
          break
        end
        seen_cursors << cursor
        pages += 1
      end
      if cursor.present? && !reached_known_event && pages >= [ max_pages, MAX_TIMELINE_PAGES ].min
        warnings << "timeline pagination truncated for #{topic}"
        complete = false
      end
      events = items.map { |item| build_skeleton_event(item, warnings: warnings) }
      [ events, newest_event_id, warnings, complete ]
    end

    def build_skeleton_event(item, warnings: nil)
      category = item["category"].presence || EVENT_TYPE_CATEGORIES[item["eventType"].to_s]
      classified = item.merge("category" => category)
      if warnings &&
          item["eventType"].present? &&
          Provider::TradeRepublicTimelineEvent.classify(classified) == :unknown
        warnings << "unsupported timeline event type #{item["eventType"]}"
      end
      build_normalized_event(item, category: category, detail: nil)
    end

    # Shared detail budget: reserve capacity for newly discovered trade events,
    # drain oldest stored incomplete / price-backfill events next, then spend
    # any leftover on additional new events. Failed attempts still consume
    # budget so a bad event cannot starve the rest of the queue forever within
    # one sync.
    def enrich_timeline_details(websocket, events, enrich_events: [])
      warnings = []
      events = Array(events)
      new_candidates = events.select { |event| self.class.incomplete_trade_detail_event?(event) && event["id"].present? }
      new_ids = new_candidates.to_set { |event| event["id"].to_s }
      backlog_candidates = Array(enrich_events).select do |event|
        next false unless event.is_a?(Hash)

        item = event.stringify_keys
        next false if item["id"].blank?
        next false if new_ids.include?(item["id"].to_s)

        self.class.incomplete_trade_detail_event?(item) ||
          self.class.trade_detail_needs_price_backfill?(item)
      end

      budget = MAX_TIMELINE_DETAILS
      reserved = [ new_candidates.size, MAX_TIMELINE_DETAILS_DELTA_RESERVED, budget ].min
      primary_new = new_candidates.first(reserved)
      remaining_new = new_candidates.drop(reserved)
      remaining_budget = budget - primary_new.size
      backlog_batch = backlog_candidates.first(remaining_budget)
      leftover = remaining_budget - backlog_batch.size
      secondary_new = remaining_new.first(leftover)

      queue = primary_new.map { |event| [ event, :new ] } +
              backlog_batch.map { |event| [ event, :backfill ] } +
              secondary_new.map { |event| [ event, :new ] }

      if new_candidates.size + backlog_candidates.size > queue.size
        warnings << "detail enrichment truncated to #{queue.size} of #{new_candidates.size + backlog_candidates.size} events"
      end

      enriched_by_id = {}
      detail_backfill_count = 0
      details_fetched = 0

      queue.each do |event, kind|
        break if details_fetched >= budget

        item = event.stringify_keys
        category = item["category"].presence || EVENT_TYPE_CATEGORIES[item["eventType"].to_s]
        next if item["id"].blank? || category.blank?
        next unless Provider::TradeRepublicTimelineEvent.importable?(item)

        details_fetched += 1
        begin
          detail = normalize_event_detail(
            subscribe(websocket, type: "timelineDetailV2", id: item["id"]),
            item: item
          )
          enriched_by_id[item["id"].to_s] = build_normalized_event(item, category: category, detail: detail)
          detail_backfill_count += 1 if kind == :backfill
        rescue TransientProviderError, Timeout, RateLimited
          raise
        rescue Error
          warnings << "detail fetch failed for event #{item["id"]}"
        end
      end

      merged_events = events.map do |event|
        id = event["id"].to_s
        enriched = enriched_by_id.delete(id)
        enriched ? prefer_richer_event(event, enriched) : event
      end
      # Backfilled stored events that were not on this sync's timeline pages.
      merged_events = merge_enriched_events(merged_events, enriched_by_id.values)

      [ merged_events, warnings, detail_backfill_count ]
    end

    # Test/helper wrapper: enrich a raw timeline page without touching the list cursor.
    def resolve_details(websocket, items, newest_event_id, warnings)
      events = Array(items).map { |item| build_skeleton_event(item, warnings: warnings) }
      enriched, detail_warnings, = enrich_timeline_details(websocket, events, enrich_events: [])
      [ enriched, newest_event_id, warnings.concat(detail_warnings) ]
    end

    def enrich_event_details(websocket, events, max: MAX_TIMELINE_DETAILS)
      warnings = []
      candidates = Array(events).select { |event| event.is_a?(Hash) && event.stringify_keys["id"].presence }
      if candidates.size > max
        warnings << "detail enrichment truncated to #{max} of #{candidates.size} events"
        candidates = candidates.first(max)
      end
      enriched, enrich_warnings, = enrich_timeline_details(websocket, [], enrich_events: candidates)
      [ enriched, warnings + enrich_warnings ]
    end

    def merge_enriched_events(events, enriched_events)
      by_id = {}
      (Array(events) + Array(enriched_events)).each do |event|
        next unless event.is_a?(Hash)

        key = event["id"].presence || event
        by_id[key] = prefer_richer_event(by_id[key], event)
      end
      by_id.values
    end

    def prefer_richer_event(previous, incoming)
      return incoming if previous.blank?
      return previous if incoming.blank?

      previous = previous.stringify_keys
      incoming = incoming.stringify_keys
      merged = previous.merge(incoming)
      merged["category"] = incoming["category"].presence || previous["category"]
      merged["detail"] = prefer_richer_detail(previous["detail"], incoming["detail"])
      Provider::TradeRepublicTimelineEvent.merge_lifecycle_fields!(merged, previous, incoming)
      # compact drops nil only; boolean false for deleted/hidden must survive.
      merged.compact
    end

    def prefer_richer_detail(previous, incoming)
      previous = previous.is_a?(Hash) ? previous.stringify_keys : {}
      incoming = incoming.is_a?(Hash) ? incoming.stringify_keys : {}
      return previous.presence if incoming.blank?
      return incoming.presence if previous.blank?

      previous.merge(incoming) { |_key, old_value, new_value| new_value.presence || old_value }.presence
    end

    def build_normalized_event(item, category:, detail:)
      item = item.stringify_keys
      amount = item.dig("amount", "value")
      event_detail = {
        "amount" => amount,
        "signed_amount" => amount,
        "currency" => item.dig("amount", "currency")
      }.compact
      detail ||= {}
      detail = event_detail.merge(detail) if event_detail.present?
      event = item.slice("id", "timestamp", "title", "subtitle", "eventType")
        .merge("category" => category, "detail" => detail.presence)

      Provider::TradeRepublicTimelineEvent::LIFECYCLE_KEYS.each do |key|
        next unless item.key?(key)
        next if key == "badge" && item[key].blank?

        event[key] = item[key]
      end

      event
    end

    def normalize_event_detail(raw, item: nil)
      rows = collect_sections(raw).flat_map { |section| Array(section["data"]) }.select { |row| row.is_a?(Hash) }
      shares = find_row(rows, SHARE_TITLES)
      total = find_row(rows, TOTAL_TITLES)
      price_row = find_row(rows, PRICE_TITLES)
      fees = find_row(rows, FEE_TITLES)
      taxes = find_row(rows, TAX_TITLES)
      quantity = decimal_from_row(shares) || quantity_from_raw(raw)
      title = shares&.dig("title").to_s.downcase
      quantity = -quantity.abs if title.include?("entfernt") || title.include?("removed") || title.include?("gesendet") || title.include?("sent")
      subtitle = item&.dig("subtitle").to_s.downcase
      quantity = -quantity.abs if quantity && SELL_SUBTITLE_MARKERS.any? { |marker| subtitle.include?(marker) }
      amount = decimal_from_row(total)
      fee_amount = decimal_from_row(fees)
      tax_amount = decimal_from_row(taxes)
      price = decimal_from_row(price_row)
      if price.nil? && quantity&.nonzero? && amount
        # Provider cash totals embed costs: buy total = gross + fees/taxes,
        # sell total = gross - fees/taxes. Recover share price accordingly.
        # Quantity is already signed negative for sells (subtitle/title markers).
        deductions = fee_amount.to_d.abs + tax_amount.to_d.abs
        gross = quantity.negative? ? amount.abs + deductions : amount.abs - deductions
        price = gross / quantity.abs if gross.positive?
      end
      return nil if quantity.nil? && amount.nil?

      {
        "isin" => find_isin(item) || find_isin(raw),
        "name" => item&.dig("title") || find_asset_name(raw),
        "quantity" => decimal_string(quantity),
        "price" => decimal_string(price),
        "amount" => decimal_string(amount&.abs),
        "currency" => currency_from_row(total) || currency_from_row(shares) || currency_from_row(price_row),
        "fees" => decimal_string(fee_amount),
        "taxes" => decimal_string(tax_amount)
      }.compact
    end

    def collect_sections(node, result = [])
      case node
      when Hash
        result << node if node.key?("title") && node["data"].is_a?(Array)
        node.each_value { |value| collect_sections(value, result) }
      when Array then node.each { |value| collect_sections(value, result) }
      end
      result
    end

    def find_row(rows, titles) = rows.find { |row| titles.include?(row["title"].to_s.downcase.strip) }

    def decimal_from_row(row)
      text = row&.dig("detail", "text") || row&.dig("detail", "value", "text")
      return nil if text.blank?

      normalized = text.to_s.gsub(/[^\d,.-]/, "")
      return nil if normalized.blank?

      # European: 1.024,92 or 511,96 → strip thousand dots, comma as decimal.
      # English: 1,024.92 → strip thousand commas. Leave plain 511.96 alone.
      if normalized.count(",") == 1 && (dot = normalized.rindex(".")) && normalized.rindex(",") > dot
        normalized = normalized.gsub(".", "").tr(",", ".")
      elsif normalized.count(",") == 1 && normalized.rindex(".").nil?
        normalized = normalized.tr(",", ".")
      elsif normalized.count(",") >= 1 && normalized.count(".") == 1 &&
          normalized.rindex(",") < normalized.rindex(".")
        normalized = normalized.gsub(",", "")
      end

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def quantity_from_raw(raw)
      value = nil
      walk(raw) do |node|
        next unless node.is_a?(String)

        match = node.match(/\A\s*([\d.,]+)\s*[×x]/)
        value ||= BigDecimal(match[1].tr(",", ".")) if match
      end
      value
    rescue ArgumentError
      nil
    end

    def currency_from_row(row) = row&.dig("detail", "value", "currency")

    def find_isin(raw)
      values = []
      walk(raw) { |value| values << value if value.is_a?(String) && value.match?(/\A[A-Z]{2}[A-Z0-9]{9}\d\z/) }
      values.first
    end

    def find_asset_name(raw)
      rows = collect_sections(raw).flat_map { |section| Array(section["data"]) }
      row = rows.find { |candidate| %w[wertpapier asset vermögenswert security].include?(candidate["title"].to_s.downcase) }
      row&.dig("detail", "text") || row&.dig("detail", "value", "text")
    end

    def walk(node, &block)
      yield node
      case node
      when Hash then node.each_value { |value| walk(value, &block) }
      when Array then node.each { |value| walk(value, &block) }
      end
    end

    def decimal_string(value) = value.blank? ? nil : value.to_s.strip
end
