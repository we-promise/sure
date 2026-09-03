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
  DETAIL_CATEGORIES = %w[orderExecution PAYMENT_RECEIVED POC_CREATED INTEREST_PAYOUT_CREATED DIVIDEND].freeze
  EVENT_TYPE_CATEGORIES = {
    "TRADING_TRADE_EXECUTED" => "orderExecution",
    "TRADE_INVOICE" => "orderExecution",
    "ORDER_EXECUTED" => "orderExecution",
    "CRYPTO_INVOICE" => "orderExecution",
    "SAVINGS_PLAN_EXECUTED" => "orderExecution",
    "TRADING_SAVINGSPLAN_EXECUTED" => "orderExecution",
    "PRIVATE_MARKET_FUND_TRADE_EXECUTED" => "orderExecution",
    "IPO_TRADE_EXECUTED" => "orderExecution",
    "BANK_TRANSACTION_INCOMING" => "PAYMENT_RECEIVED",
    "INCOMING_TRANSFER" => "PAYMENT_RECEIVED",
    "INCOMING_TRANSFER_DELEGATION" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND_SEPA_DIRECT_DEBIT" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND_APPLE_PAY" => "PAYMENT_RECEIVED",
    "BANK_TRANSACTION_OUTGOING" => "POC_CREATED",
    "BANK_TRANSACTION_OUTGOING_DIRECT_DEBIT" => "POC_CREATED",
    "OUTGOING_TRANSFER" => "POC_CREATED",
    "OUTGOING_TRANSFER_DELEGATION" => "POC_CREATED",
    "PAYMENT_OUTBOUND" => "POC_CREATED",
    "CARD_TRANSACTION" => "POC_CREATED",
    "card_successful_transaction" => "POC_CREATED",
    # Trade Republic currently uses CARD_CASH_BACK for some card purchases
    # (for example, Marktkauf), not only for actual cashback credits. The
    # signed provider amount confirms these are cash outflows.
    "CARD_CASH_BACK" => "POC_CREATED",
    "card_refund" => "PAYMENT_RECEIVED",
    "CARD_REFUND" => "PAYMENT_RECEIVED",
    "SPARE_CHANGE_AGGREGATE" => "POC_CREATED",
    "SAVEBACK_AGGREGATE" => "POC_CREATED",
    "BANK_TRANSACTION_OUTGOING_SCHEDULED" => "POC_CREATED",
    "CARD_ATM_WITHDRAWAL" => "POC_CREATED",
    "SSP_CORPORATE_ACTION_CASH" => "DIVIDEND",
    "ssp_corporate_action_invoice_cash" => "DIVIDEND",
    "SSP_CORPORATE_ACTION_CASH_NON_DIVIDEND" => "PAYMENT_RECEIVED",
    "DIVIDEND" => "DIVIDEND",
    "CREDIT" => "DIVIDEND",
    "INTEREST_PAYOUT" => "INTEREST_PAYOUT_CREATED",
    "INTEREST_PAYOUT_CREATED" => "INTEREST_PAYOUT_CREATED",
    "TAX_REFUND" => "PAYMENT_RECEIVED",
    "ssp_tax_correction_invoice" => "PAYMENT_RECEIVED",
    "SSP_TAX_CORRECTION" => "PAYMENT_RECEIVED",
    "CARD_ORDER_FEE" => "POC_CREATED"
  }.freeze
  PORTFOLIO_CATEGORIES = {
    "stocksAndETFs" => "brokerage",
    "privateMarkets" => "private_markets",
    "interest" => "interest_products",
    "bonds" => "interest_products",
    "cryptos" => "crypto_wallet"
  }.freeze
  TICKER_EXCHANGES = %w[LSX BHS TUB SGL BVT].freeze
  CRYPTO_TICKER_EXCHANGES = %w[BHS TUB SGL BVT LSX].freeze
  FEE_TITLES = [ "gebühr", "fee" ].freeze
  TAX_TITLES = [ "steuer", "steuern", "tax", "taxes" ].freeze
  MAX_TIMELINE_PAGES = 50
  MAX_TIMELINE_DETAILS = 200
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

  def sync(session_txt:, known_newest_event_id: nil, timeline_max_pages: MAX_TIMELINE_PAGES)
    raise ConfigurationError, "session_txt is required" if session_txt.blank?

    with_retry do
      sync_once(
        session_txt: session_txt,
        known_newest_event_id: known_newest_event_id,
        timeline_max_pages: timeline_max_pages
      )
    end
  end

  def sync_once(session_txt:, known_newest_event_id:, timeline_max_pages:)
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
        positions, position_warnings = normalize_positions(websocket, portfolio)
        warnings.concat(position_warnings)
        domain_statuses["portfolio"] = "success"
        domain_statuses["instrument_metadata"] = position_warnings.empty? ? "success" : "partial"
      rescue MalformedResponse, ProviderUnavailable => e
        raise if e.is_a?(TransientProviderError)
        warnings << "portfolio fetch failed: #{e.message}"
      end

      events = []
      newest_event_id = nil
      timeline_warnings = []
      timeline_complete = false
      begin
        events, newest_event_id, timeline_warnings, timeline_complete = collect_all_timeline(
          websocket,
          known_newest_event_id: known_newest_event_id,
          max_pages: timeline_max_pages.to_i
        )
        warnings.concat(timeline_warnings)
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
        "positions" => positions, "events" => events, "newest_event_id" => newest_event_id,
        "warnings" => warnings, "position_warnings" => position_warnings
      })
    ensure
      websocket.close
    end
  rescue Provider::TradeRepublicClient::Timeout
    raise Timeout, "Trade Republic WebSocket timed out"
  end

  class << self
    def available? = !!defined?(WebSocket::Driver)
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

    def normalize_positions(websocket, portfolio)
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
      valid_positions.each do |position|
        isin = position["instrumentId"].presence || position["isin"]
        next if prices.key?(isin)

        price = position_price(websocket, isin, position["categoryType"])
        prices[isin] = price if price.present?
        warnings << "price unavailable for #{isin}; position kept without valuation" if price.blank?
      end

      positions = valid_positions.map do |position|
        isin = position["instrumentId"].presence || position["isin"]
        quantity = position["netSize"] || position["quantity"]
        { "isin" => isin, "name" => position["name"], "category" => portfolio_category(position["categoryType"]), "quantity" => decimal_string(quantity), "average_cost" => decimal_string(position["averageBuyIn"] || position["avgCost"]), "price" => prices[isin] }.compact
      end
      [ positions, warnings ]
    end

    def position_price(websocket, isin, category_type)
      exchanges = category_type.to_s == "cryptos" ? CRYPTO_TICKER_EXCHANGES : TICKER_EXCHANGES
      exchanges.each do |exchange|
        ticker = subscribe(websocket, type: "ticker", id: "#{isin}.#{exchange}")
        price = ticker.dig("last", "price") if ticker.is_a?(Hash)
        return decimal_string(price) if price.present?
      rescue Timeout
        # A ticker that never answers is instrument-metadata loss, not a
        # failed portfolio snapshot. Keep the holding and let the importer
        # record the missing valuation instead of retrying the whole sync.
        return nil
      rescue TransientProviderError, RateLimited
        raise
      rescue Error
        next
      end

      nil
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

    def collect_all_timeline(websocket, known_newest_event_id:, max_pages:)
      transaction_events, transaction_cursor, transaction_warnings, transaction_complete = collect_timeline_topic(
        websocket,
        topic: "timelineTransactions",
        known_newest_event_id: known_newest_event_id,
        max_pages: max_pages
      )
      activity_events, activity_cursor, activity_warnings, activity_complete = collect_timeline_topic(
        websocket,
        topic: "timelineActivityLog",
        known_newest_event_id: known_newest_event_id,
        max_pages: max_pages
      )
      events = (transaction_events + activity_events).uniq do |event|
        event["id"].presence || event.slice("timestamp", "eventType", "title", "subtitle", "detail")
      end
      newest_event = events.max_by { |event| event["timestamp"].to_s }
      details_incomplete = (transaction_events.any? && transaction_cursor.nil?) ||
        (activity_events.any? && activity_cursor.nil?)
      timeline_complete = transaction_complete != false && activity_complete != false &&
        !details_incomplete &&
        (transaction_warnings + activity_warnings).none? { |warning| warning.start_with?("detail fetch failed") }
      [
        events,
        details_incomplete ? nil : (newest_event&.dig("id") || transaction_cursor || activity_cursor),
        transaction_warnings + activity_warnings,
        timeline_complete
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
      details, resolved_newest_event_id, detail_warnings = resolve_details(websocket, items, newest_event_id, warnings)
      [ details, resolved_newest_event_id, detail_warnings, complete ]
    end

    def resolve_details(websocket, items, newest_event_id, warnings)
      events = []
      details_fetched = 0
      details_skipped = false
      items.each do |item|
        detail = nil
        category = item["category"].presence || EVENT_TYPE_CATEGORIES[item["eventType"].to_s]
        warnings << "unsupported timeline event type #{item["eventType"]}" if category.blank?
        if DETAIL_CATEGORIES.include?(category.to_s) && details_fetched < MAX_TIMELINE_DETAILS
          begin
            detail = normalize_event_detail(
              subscribe(websocket, type: "timelineDetailV2", id: item["id"]),
              item: item
            )
            details_fetched += 1
          rescue TransientProviderError, Timeout, RateLimited
            raise
          rescue Error
            warnings << "detail fetch failed for event #{item["id"]}"
          end
        elsif DETAIL_CATEGORIES.include?(category.to_s)
          details_skipped = true
        end
        amount = item.dig("amount", "value")
        event_detail = {
          "amount" => amount,
          "signed_amount" => amount,
          "currency" => item.dig("amount", "currency")
        }.compact
        detail ||= {}
        detail = event_detail.merge(detail) if event_detail.present?
        events << item.slice("id", "timestamp", "title", "subtitle", "eventType")
          .merge("category" => category, "detail" => detail.presence)
      end
      newest_event_id = nil if details_skipped || events.any? { |event| DETAIL_CATEGORIES.include?(event["category"]) && event["detail"].nil? }
      [ events, newest_event_id, warnings ]
    end

    def normalize_event_detail(raw, item: nil)
      rows = collect_sections(raw).flat_map { |section| Array(section["data"]) }.select { |row| row.is_a?(Hash) }
      shares = find_row(rows, [ "aktien", "anteile", "shares", "aktien hinzugefügt", "shares added", "aktien erhalten", "shares received", "aktien entfernt", "shares removed", "aktien gesendet", "shares sent" ])
      total = find_row(rows, [ "gesamt", "total" ])
      fees = find_row(rows, FEE_TITLES)
      taxes = find_row(rows, TAX_TITLES)
      quantity = decimal_from_row(shares) || quantity_from_raw(raw)
      title = shares&.dig("title").to_s.downcase
      quantity = -quantity.abs if title.include?("entfernt") || title.include?("removed") || title.include?("gesendet") || title.include?("sent")
      quantity = -quantity.abs if quantity && item&.dig("subtitle").to_s.downcase.include?("sell")
      amount = decimal_from_row(total)
      return nil if quantity.nil? && amount.nil?
      { "isin" => find_isin(item) || find_isin(raw), "name" => item&.dig("title") || find_asset_name(raw), "quantity" => decimal_string(quantity), "price" => nil, "amount" => decimal_string(amount&.abs), "currency" => currency_from_row(total) || currency_from_row(shares), "fees" => decimal_string(decimal_from_row(fees)), "taxes" => decimal_string(decimal_from_row(taxes)) }.compact
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
      normalized = normalized.gsub(".", "").tr(",", ".") if normalized.count(",") == 1 && normalized.rindex(",") > normalized.rindex(".")
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
