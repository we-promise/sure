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
  # The websocket failed during the history backfill. The sync is retried
  # without the backfill, so one bad backfill page cannot block the rest of
  # the import, and the failure counts towards abandoning the backfill.
  # The pages read before the failure and the cursor to resume at are kept.
  class TimelineBackfillInterrupted < TransientProviderError
    attr_reader :topic, :reason, :cursor, :events

    def initialize(message = nil, topic:, reason:, cursor:, events: [])
      @topic = topic
      @reason = reason
      @cursor = cursor
      @events = events
      super(message)
    end
  end

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
  # Ordinary cash movements (card payments, transfers, interest) use the
  # timeline list amount only and must not consume the detail budget.
  TRADE_DETAIL_CATEGORY = "orderExecution"
  TRADE_DETAIL_EVENT_TYPES = %w[
    SAVEBACK_AGGREGATE
    SPARE_CHANGE_AGGREGATE
  ].freeze
  # New dividends also fetch timelineDetailV2 so provider_detail keeps the
  # ISIN, share count, dividend per share and withholding tax. The imported
  # cash amount still comes from the timeline list.
  DIVIDEND_DETAIL_CATEGORY = Provider::TradeRepublicTimelineEvent::CATEGORY_DIVIDEND
  DIVIDEND_DETAIL_KEYS = %w[isin name quantity dividend_per_share taxes].freeze
  DIVIDEND_PER_SHARE_TITLES = [
    "dividend per share", "dividende pro aktie", "dividend per aandeel", "ausschüttung pro anteil"
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
  # Bonds are left out: Trade Republic lists every bond on LSX under the same
  # placeholder symbol "BOND", so they resolve by ISIN instead.
  INSTRUMENT_SYMBOL_CATEGORIES = %w[stocksAndETFs].freeze
  BOND_INSTRUMENT_TYPE = "bond"
  BOND_PLACEHOLDER_SYMBOL = "BOND"
  BOND_PLACEHOLDER_EXCHANGE = "LSX"
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
  # Bond executions list a nominal amount and a price in percent of par
  # instead of shares and a share price.
  NOMINAL_TITLES = [ "nennwert", "face value" ].freeze
  QUOTATION_TITLES = [ "quotation" ].freeze
  BOND_TOTAL_TITLES = [ "summe", "total" ].freeze
  SELL_SUBTITLE_MARKERS = %w[sell verkauf verkaufen verkopen].freeze
  MAX_TIMELINE_PAGES = 50
  TIMELINE_TOPICS = %w[timelineTransactions timelineActivityLog].freeze
  # A history backfill that keeps failing on the same cursor (for example an
  # expired one) is abandoned instead of being retried forever.
  MAX_TIMELINE_BACKFILL_FAILURES = 5
  MAX_TIMELINE_CURSOR_LENGTH = 1_024
  # Stored per topic in trade_republic_items.timeline_cursors:
  #   { topic => { "newest_event_id", "backfill_cursor", "backfill_stop_event_id", "backfill_failures" } }
  # A backfill without a stop event reads the history to the end of the topic;
  # one with a stop event fills a gap of new events down to that event.
  TIMELINE_BACKFILL_KEYS = %w[backfill_cursor backfill_stop_event_id backfill_failures].freeze
  private_constant :TIMELINE_BACKFILL_KEYS
  MAX_TIMELINE_DETAILS = 200
  # Reserve this many detail fetches for newly discovered trade events each
  # sync. The remainder drains the oldest stored incomplete events; leftover
  # budget returns to additional new events.
  MAX_TIMELINE_DETAILS_DELTA_RESERVED = 50
  # Unsuccessful price backfills and symbol lookups are retried at most once
  # per RETRY_INTERVAL, and stop once RETRY_WINDOW has passed (since the trade
  # for prices, since the first failed attempt for symbols).
  RETRY_INTERVAL = 1.day
  RETRY_WINDOW = 30.days
  PRICE_BACKFILL_ATTEMPTED_AT_KEY = "price_backfill_attempted_at"
  SYMBOL_LOOKUP_ATTEMPTED_AT_KEY = "symbol_lookup_attempted_at"
  SYMBOL_LOOKUP_FIRST_ATTEMPTED_AT_KEY = "symbol_lookup_first_attempted_at"
  # Stored trades whose detail is still incomplete after a fetch; the backlog
  # retries the least recently attempted first.
  DETAIL_BACKFILL_ATTEMPTED_AT_KEY = "detail_backfill_attempted_at"
  RETRY_MARKER_KEYS = [
    PRICE_BACKFILL_ATTEMPTED_AT_KEY, SYMBOL_LOOKUP_ATTEMPTED_AT_KEY, SYMBOL_LOOKUP_FIRST_ATTEMPTED_AT_KEY,
    DETAIL_BACKFILL_ATTEMPTED_AT_KEY
  ].freeze
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

  # One walk through a timeline topic. `outcome` is :finished (end of the
  # topic), :caught_up (reached the stop event), :budget_exhausted (`cursor`
  # is where to continue), :stalled (pagination broke off at `cursor`) or
  # :failed (the page at `cursor` raised `error`).
  TimelinePass = Data.define(:events, :newest_event_id, :warnings, :outcome, :cursor, :error) do
    def initialize(error: nil, **attributes) = super
  end
  # One topic's events this sync and its state for the next sync.
  # `head_complete` is false when the newest pages stalled.
  TopicSync = Data.define(:events, :newest_event_id, :warnings, :head_complete, :state)
  # `cursors` holds the next per-topic state: the newest event id the head
  # pass stops at, and the history backfill position. `topic_event_ids` lists
  # the ids of the events each topic fetched.
  TimelineSync = Data.define(:events, :newest_event_id, :warnings, :pagination_complete, :detail_backfill_count, :cursors, :topic_event_ids)

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
    # A scanned challenge is single-use: once it yields a processId, polling
    # the challenge again answers ALREADY_PROCESSED, so follow the process.
    process_id = pending["process_id"].presence

    unless process_id
      challenge_response = session.get(
        "/api/v2/auth/web/login/qr-challenges/#{escape_path(pending.fetch("challenge_id"))}",
        headers: session.login_headers
      )
      raise_http_error(challenge_response, login: true)
      challenge = parse_json(challenge_response)
      process_id = challenge["processId"].presence

      if process_id.blank? && login_process_completed?(challenge)
        return authenticated_qr_session_result(session, pending)
      end

      unless process_id
        qr_code_payload = challenge["qrCodePayload"].presence || pending["qr_code_payload"]
        next_pending = pending.merge(
          "session_blob" => session.cookies_blob,
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
    end

    pending = pending.merge("process_id" => process_id)
    begin
      process_response = session.get(
        "/api/v2/auth/web/login/processes/#{escape_path(process_id)}",
        headers: session.login_headers
      )
      raise_http_error(process_response, login: true)
    rescue RateLimited, Timeout, TransientProviderError => e
      attach_pending_login_state(e, pending.merge("session_blob" => session.cookies_blob))
      raise
    end
    pending = pending.merge("session_blob" => session.cookies_blob)
    process = parse_json(process_response)
    unless login_process_completed?(process)
      return Result.new(data: {
        "status" => "pending",
        "process_id" => process_id,
        "pending_login_b64" => encode_pending(pending)
      })
    end

    authenticated_qr_session_result(session, pending)
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

  def sync(session_txt:, known_newest_event_id: nil, timeline_cursors: {}, timeline_max_pages: MAX_TIMELINE_PAGES, enrich_events: [], symbol_lookup_isins: [], known_instrument_symbols: {})
    raise ConfigurationError, "session_txt is required" if session_txt.blank?

    interrupted_backfills = {}
    with_retry do
      sync_once(
        session_txt: session_txt,
        known_newest_event_id: known_newest_event_id,
        timeline_cursors: timeline_cursors,
        timeline_max_pages: timeline_max_pages,
        enrich_events: enrich_events,
        symbol_lookup_isins: symbol_lookup_isins,
        known_instrument_symbols: known_instrument_symbols,
        interrupted_backfills: interrupted_backfills
      )
    rescue TimelineBackfillInterrupted => e
      interrupted_backfills = interrupted_backfills.merge(e.topic => { reason: e.reason, cursor: e.cursor, events: e.events })
      raise
    end
  end

  def sync_once(session_txt:, known_newest_event_id:, timeline_max_pages:, timeline_cursors: {}, enrich_events: [], symbol_lookup_isins: [], known_instrument_symbols: {}, interrupted_backfills: {})
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

      cash = nil
      begin
        # "cash" is the booked balance. "availableCash" additionally subtracts
        # funds reserved for open (e.g. limit) orders, which have not left the
        # account yet, so it must not be used as the account balance.
        cash = subscribe(websocket, type: "cash")
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
          sec_acc_no: account["securitiesAccountNumber"],
          known_instrument_symbols: known_instrument_symbols
        )
        warnings.concat(position_warnings)
        domain_statuses["portfolio"] = "success"
        domain_statuses["instrument_metadata"] = position_warnings.empty? ? "success" : "partial"
      rescue MalformedResponse, ProviderUnavailable => e
        raise if e.is_a?(TransientProviderError)
        warnings << "portfolio fetch failed: #{e.message}"
      end

      known_symbols = self.class.instrument_symbols_from_positions(positions)
      instrument_symbols = known_symbols.dup
      unresolved_symbol_isins = []

      timeline = nil
      begin
        timeline = collect_all_timeline(
          websocket,
          known_newest_event_id: known_newest_event_id,
          max_pages: timeline_max_pages.to_i,
          enrich_events: enrich_events,
          timeline_cursors: timeline_cursors,
          interrupted_backfills: interrupted_backfills
        )
        instrument_symbols = enrich_trade_instrument_symbols(
          websocket,
          timeline.events,
          known_symbols: known_symbols,
          extra_isins: symbol_lookup_isins,
          unresolved: unresolved_symbol_isins
        )
        warnings.concat(timeline.warnings)
        # Timeline domain reflects the newest pages only. The history backfill
        # and detail backlog drain across later syncs and must not freeze
        # newest_event_id.
        domain_statuses["timeline"] = timeline.pagination_complete ? "success" : "partial"
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
          "currency" => money_currency(cash)
        }.compact),
        "positions" => positions,
        "events" => timeline&.events || [],
        "instrument_symbols" => instrument_symbols,
        "unresolved_symbol_isins" => unresolved_symbol_isins,
        "newest_event_id" => timeline&.newest_event_id,
        "timeline_pagination_complete" => timeline&.pagination_complete || false,
        "timeline_cursors" => timeline&.cursors,
        "timeline_topic_event_ids" => timeline&.topic_event_ids,
        "detail_backfill_count" => timeline&.detail_backfill_count || 0,
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

    # Stops the given topics' backfills that read further back in history.
    # Gap backfills fetch events newer than anything stored, so they keep
    # running.
    def stop_timeline_history_backfills(timeline_cursors, topics:)
      timeline_cursors.to_h.to_h do |topic, state|
        history_backfill = topics.include?(topic) && state.is_a?(Hash) &&
          state["backfill_cursor"].present? && state["backfill_stop_event_id"].blank?
        [ topic, history_backfill ? state.except(*TIMELINE_BACKFILL_KEYS) : state ]
      end
    end


    def pending_timeline_backfills(timeline_cursors)
      timeline_cursors.to_h.count { |_topic, state| state.is_a?(Hash) && state["backfill_cursor"].present? }
    end

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

    def dividend_detail_missing?(event)
      return false unless event.is_a?(Hash)

      item = event.stringify_keys
      category = item["category"].presence || EVENT_TYPE_CATEGORIES[item["eventType"].to_s]
      return false unless category.to_s == DIVIDEND_DETAIL_CATEGORY
      return false unless Provider::TradeRepublicTimelineEvent.importable?(item)

      detail = item["detail"]
      !(detail.is_a?(Hash) && detail.stringify_keys["isin"].present?)
    end

    # Complete trades (isin + quantity) that still lack a share price — usually
    # stored before we parsed execution price / fees from timeline details.
    # Trade Republic sometimes publishes the price late, so an unsuccessful
    # attempt is retried at most once per RETRY_INTERVAL until the trade is
    # RETRY_WINDOW old.
    def trade_detail_needs_price_backfill?(event, now = Time.current)
      return false unless trade_detail_missing_price?(event)

      attempted_at = detail_time(event, PRICE_BACKFILL_ATTEMPTED_AT_KEY)
      return true if attempted_at.nil?

      traded_at = parse_time((event["timestamp"] || event[:timestamp]))
      return false if traded_at && traded_at <= now - RETRY_WINDOW

      attempted_at <= now - RETRY_INTERVAL
    end

    # Backlog order for stored events needing details: never-attempted events
    # first, oldest first, then the least recently attempted, so events that
    # stay incomplete can't hold the budget on every sync. Price backfills
    # carry no detail attempt; trade_detail_needs_price_backfill? paces them.
    def detail_backfill_sort_key(event)
      return [ 0, "" ] unless event.is_a?(Hash)

      [ detail_time(event, DETAIL_BACKFILL_ATTEMPTED_AT_KEY).to_i, (event["timestamp"] || event[:timestamp]).to_s ]
    end

    # Stored trades whose ISIN found no usable exchange symbol are retried at
    # most once per RETRY_INTERVAL, for RETRY_WINDOW after the first attempt.
    def symbol_lookup_due?(event, now = Time.current)
      attempted_at = detail_time(event, SYMBOL_LOOKUP_ATTEMPTED_AT_KEY)
      return true if attempted_at.nil?

      first_attempted_at = detail_time(event, SYMBOL_LOOKUP_FIRST_ATTEMPTED_AT_KEY) || attempted_at
      return false if first_attempted_at <= now - RETRY_WINDOW

      attempted_at <= now - RETRY_INTERVAL
    end

    def trade_detail_missing_price?(event)
      return false unless requires_trade_detail?(event)
      return false unless Provider::TradeRepublicTimelineEvent.importable?(event)
      return false unless trade_detail_complete?(event)

      detail = (event["detail"] || event[:detail]).stringify_keys
      detail["price"].to_s.strip.blank?
    end

    # Earlier syncs stored this listing on bond positions and trades.
    def bond_placeholder_listing?(symbol, exchange_slug)
      symbol.to_s.strip.casecmp?(BOND_PLACEHOLDER_SYMBOL) &&
        exchange_slug.to_s.strip.casecmp?(BOND_PLACEHOLDER_EXCHANGE)
    end

    def bond?(detail)
      detail.is_a?(Hash) && detail.with_indifferent_access[:instrument_type].to_s == BOND_INSTRUMENT_TYPE
    end

    # The ISIN of a stored or new trade that still needs an exchange ticker,
    # or nil. Bonds never get one.
    def symbol_lookup_isin(event)
      return nil unless event.is_a?(Hash)
      return nil unless requires_trade_detail?(event)
      return nil unless Provider::TradeRepublicTimelineEvent.importable?(event)

      detail = event["detail"] || event[:detail]
      return nil unless detail.is_a?(Hash)

      detail = detail.stringify_keys
      isin = detail["isin"].to_s.presence
      return nil if isin.blank? || bond?(detail)

      symbol = detail["symbol"].to_s.strip.presence
      usable = symbol.present? && !symbol.casecmp?(isin) && detail["exchange_slug"].to_s.strip.present?
      isin unless usable
    end

    def instrument_symbols_from_positions(positions)
      Array(positions).each_with_object({}) do |position, map|
        next unless position.is_a?(Hash)

        position = position.stringify_keys
        isin = position["isin"].to_s.presence
        symbol = position["symbol"].to_s.strip.presence
        exchange_slug = position["exchange_slug"].to_s.strip.upcase.presence
        next if isin.blank? || symbol.blank? || exchange_slug.blank?
        next if symbol.casecmp?(isin)

        map[isin] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end
    end

    def detail_time(event, key)
      detail = (event["detail"] || event[:detail])
      parse_time(detail.stringify_keys[key]) if detail.is_a?(Hash)
    end

    def parse_time(value)
      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError
      nil
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

    def attach_pending_login_state(error, pending)
      pending_login_b64 = encode_pending(pending)
      error.define_singleton_method(:pending_login_b64) { pending_login_b64 }
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

    def authenticated_qr_session_result(session, pending)
      authenticated_session_result(session)
    rescue RateLimited, Timeout, TransientProviderError => e
      attach_pending_login_state(e, pending.merge("session_blob" => session.cookies_blob))
      raise
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
    rescue TransientProviderError, RateLimited
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

    # `known_instrument_symbols` are exchange tickers stored by earlier syncs;
    # those ISINs skip the instrument subscription.
    def normalize_positions(websocket, portfolio, sec_acc_no: nil, known_instrument_symbols: {})
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
      instruments = {}
      known_symbols = stringify_instrument_symbols(known_instrument_symbols)
      private_market_quotes = private_markets_unit_prices(websocket, sec_acc_no) if valid_positions.any? { |p|
        p["categoryType"].to_s == "privateMarkets"
      }

      valid_positions.each do |position|
        isin = position["instrumentId"].presence || position["isin"]
        next if prices.key?(isin)

        private_market = position["categoryType"].to_s == "privateMarkets"
        price = position_price(websocket, isin, position["categoryType"])
        # Bond tickers are quoted in percent of par (e.g. 84.04 = 84.04%),
        # while netSize is the nominal amount in currency units. Convert the
        # ticker quote to a per-unit price so quantity * price yields the
        # market value. Fallback prices below are already per unit.
        price = bond_unit_price(price) if price.present? && position["categoryType"].to_s == "bonds"
        price = private_market_quotes[isin] if price.blank? && private_market_quotes.present?
        # Private-market funds have no exchange quote. Without a
        # privateMarketsPositions unit price, value them at the average buy-in
        # rather than zero. Other categories keep the unpriced warning.
        price = decimal_string(position["averageBuyIn"] || position["avgCost"]) if price.blank? && private_market
        # Non-numeric quotes ("N/A") and non-finite ones ("NaN", "Infinity")
        # would corrupt the balance; keep the position unvalued instead.
        price = nil unless finite_decimal(price)

        if price.present?
          prices[isin] = price
        else
          warnings << "price unavailable for #{isin}; position kept without valuation"
        end
      end
      valid_positions.each do |position|
        isin = position["instrumentId"].presence || position["isin"]
        next if instruments.key?(isin)

        if position["categoryType"].to_s == "bonds"
          instruments[isin] = bond_instrument(websocket, isin)
          next
        end
        next unless INSTRUMENT_SYMBOL_CATEGORIES.include?(position["categoryType"].to_s)

        known = known_symbols[isin]
        instruments[isin] = if known
          { symbol: known["symbol"], exchange_slug: known["exchange_slug"] }
        else
          instrument_exchange_symbol(websocket, isin)
        end
      end

      positions = valid_positions.map do |position|
        isin = position["instrumentId"].presence || position["isin"]
        quantity = position["netSize"] || position["quantity"]
        instrument = instruments[isin] || {}
        {
          "isin" => isin,
          "name" => instrument[:name].presence || position["name"],
          "category" => portfolio_category(position["categoryType"]),
          "instrument_type" => instrument[:instrument_type],
          "quantity" => decimal_string(quantity),
          "average_cost" => decimal_string(position["averageBuyIn"] || position["avgCost"]),
          "price" => prices[isin],
          "symbol" => instrument[:symbol],
          "exchange_slug" => instrument[:exchange_slug]
        }.compact
      end
      [ positions, warnings ]
    end

    def bond_unit_price(percent_price)
      value = finite_decimal(percent_price)
      (value / 100).to_s("F") if value
    end

    def finite_decimal(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      decimal if decimal.finite?
    rescue ArgumentError
      nil
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
    rescue TransientProviderError, RateLimited
      raise
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
    rescue TransientProviderError, RateLimited
      raise
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
      payload = instrument_payload(websocket, isin)
      pick_instrument_exchange_symbol(payload, isin) if payload
    end

    # The portfolio names a bond by its localized maturity ("März 2040"); the
    # instrument name also carries the issuer ("ITALIEN 19/40").
    def bond_instrument(websocket, isin)
      { name: instrument_name(websocket, isin), instrument_type: BOND_INSTRUMENT_TYPE }.compact
    end

    def instrument_name(websocket, isin)
      bond_name(instrument_payload(websocket, isin))
    end

    # Bonds are named like the market lists them: issuer, coupon and maturity
    # ("Italy 3.1% Mar 2040"). The instrument name is the exchange's German
    # name ("ITALIEN 19/40") even with locale "en", so it is only the fallback.
    def bond_name(payload)
      return nil unless payload.is_a?(Hash)

      bond_info = payload["bondInfo"].is_a?(Hash) ? payload["bondInfo"] : {}
      issuer = bond_info["issuerName"].to_s.strip.presence
      maturity = payload["shortName"].to_s.strip.presence
      return payload["name"].to_s.strip.presence unless issuer && maturity

      [ issuer, bond_coupon(bond_info), maturity ].compact.join(" ")
    end

    # A fixed coupon never changes, so it can go in a name that is only set
    # when the security is created. Floating rates are left out.
    def bond_coupon(bond_info)
      return nil unless bond_info["interestRateType"] == "FIXED_INTEREST_RATE"

      rate = finite_decimal(bond_info["interestRate"])
      "#{(rate * 100).round(4).to_s("F").delete_suffix(".0")}%" if rate
    end

    def instrument_payload(websocket, isin)
      payload = optional_subscribe(websocket, type: "instrument", id: isin)
      payload if payload.is_a?(Hash)
    rescue TransientProviderError, RateLimited
      raise
    rescue Error
      nil
    end

    # Look up exchange tickers for trade ISINs that are no longer (or never)
    # present in the current portfolio snapshot — e.g. fully sold holdings.
    # `extra_isins` covers stored timeline trades that incremental syncs no
    # longer re-fetch after the newest-event cursor advances.
    # ISINs looked up without a usable symbol are appended to `unresolved`.
    def enrich_trade_instrument_symbols(websocket, events, known_symbols: {}, extra_isins: [], unresolved: [])
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
        symbol = instrument[:symbol].to_s.strip.presence if instrument.is_a?(Hash)
        exchange_slug = instrument[:exchange_slug].to_s.strip.upcase.presence if instrument.is_a?(Hash)
        if symbol.blank? || exchange_slug.blank? || symbol.casecmp?(isin)
          unresolved << isin
          next
        end

        symbols[isin] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end

      stamp_instrument_symbols_on_events!(events, symbols)
      stamp_bond_instrument_names!(websocket, events, budget: MAX_INSTRUMENT_LOOKUPS - looked_up)
      symbols
    end

    # A sold bond has no position to name its ISIN security after, and its
    # timeline title only names the maturity ("März 2040"). Stamp the
    # instrument name on bond trades while they pass through a sync, so the
    # security is created with it.
    def stamp_bond_instrument_names!(websocket, events, budget:)
      names = {}
      Array(events).each do |event|
        next unless event.is_a?(Hash)

        detail = event["detail"] || event[:detail]
        next unless self.class.bond?(detail)

        detail = detail.stringify_keys
        isin = detail["isin"].to_s.presence
        next if isin.blank? || detail["instrument_name"].present?

        unless names.key?(isin)
          next if names.size >= budget

          names[isin] = instrument_name(websocket, isin)
        end
        next if names[isin].blank?

        detail["instrument_name"] = names[isin]
        event["detail"] = detail
      end
      events
    end

    def trade_isins_missing_symbols(events, known_symbols)
      Array(events).filter_map do |event|
        isin = self.class.symbol_lookup_isin(event)
        isin unless isin.nil? || known_symbols.key?(isin)
      end.uniq
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
      return nil if payload["typeId"].to_s == BOND_INSTRUMENT_TYPE

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

    def collect_all_timeline(websocket, known_newest_event_id:, max_pages:, enrich_events: [], timeline_cursors: {}, interrupted_backfills: {})
      timeline_cursors = (timeline_cursors || {}).to_h.stringify_keys
      topics = TIMELINE_TOPICS.index_with do |topic|
        state = timeline_cursors[topic].is_a?(Hash) ? timeline_cursors[topic].stringify_keys : {}
        sync_timeline_topic(
          websocket,
          topic: topic,
          state: state,
          fallback_newest_event_id: known_newest_event_id,
          max_pages: max_pages,
          interrupted_backfill: interrupted_backfills[topic]
        )
      end.values
      skeleton_events = topics.flat_map(&:events).uniq do |event|
        event["id"].presence || event.slice("timestamp", "eventType", "title", "subtitle", "detail")
      end
      events, detail_warnings, detail_backfill_count = enrich_timeline_details(
        websocket,
        skeleton_events,
        enrich_events: enrich_events
      )
      # Backfilled stored events are older than this sync's pages and must not
      # pull the list cursor backwards.
      newest_event = skeleton_events.max_by { |event| event["timestamp"].to_s }
      TimelineSync.new(
        events: events,
        newest_event_id: newest_event&.dig("id") || topics.filter_map(&:newest_event_id).first,
        warnings: topics.flat_map(&:warnings) + detail_warnings,
        # Newest pages only — the history backfill and pending details drain on
        # later syncs.
        pagination_complete: topics.all?(&:head_complete),
        detail_backfill_count: detail_backfill_count,
        cursors: TIMELINE_TOPICS.zip(topics.map(&:state)).to_h.compact_blank,
        topic_event_ids: TIMELINE_TOPICS.zip(topics.map { |topic| topic.events.filter_map { |event| event["id"].presence&.to_s } }).to_h
      )
    end

    # Reads a topic's newest pages down to the event the previous sync stopped
    # at, then continues the history backfill. When more pages remain than the
    # budget allows (a first sync of a long history, or a gap of new events
    # since the last sync) the backfill takes over from where the newest pages
    # ran out, so older events are imported over several syncs.
    #
    # The per-topic newest event is authoritative. The item's single
    # newest_event_id only seeds topics synced before per-topic state existed.
    def sync_timeline_topic(websocket, topic:, state:, fallback_newest_event_id:, max_pages:, interrupted_backfill: nil)
      known_newest_event_id = state["newest_event_id"].presence || fallback_newest_event_id.presence
      head = collect_timeline_topic(websocket, topic: topic, known_newest_event_id: known_newest_event_id, max_pages: max_pages)
      events = head.events
      warnings = head.warnings.dup
      head_complete = head.outcome != :stalled

      if head_complete
        state = state.merge("newest_event_id" => head.newest_event_id || known_newest_event_id).compact
        if head.outcome == :budget_exhausted
          # A gap stops at the previous newest event. A backfill that was still
          # running is replaced, so the new one reads down to its stop event
          # (or to the end of the topic) to cover that range too.
          stop_event_id = state["backfill_cursor"].present? ? state["backfill_stop_event_id"] : known_newest_event_id
          state = start_timeline_backfill(state, topic: topic, cursor: head.cursor, stop_event_id: stop_event_id, warnings: warnings)
        end
      end

      if interrupted_backfill
        # The websocket failed during this topic's backfill, and the sync is
        # now being retried without it. The pages read before the failure are
        # kept and the backfill resumes at the failed page on the next sync.
        # Backfills of other topics still run.
        if state["backfill_cursor"].present?
          events += interrupted_backfill[:events]
          state = timeline_backfill_stopped(state, cursor: interrupted_backfill[:cursor], topic: topic, reason: interrupted_backfill[:reason], warnings: warnings)
        end
      elsif state["backfill_cursor"].present?
        backfill_events, state = continue_timeline_backfill(websocket, topic: topic, state: state, max_pages: max_pages, warnings: warnings)
        events += backfill_events
      end

      TopicSync.new(events: events, newest_event_id: head.newest_event_id, warnings: warnings, head_complete: head_complete, state: state)
    end

    def start_timeline_backfill(state, topic:, cursor:, stop_event_id:, warnings:)
      state = state.except(*TIMELINE_BACKFILL_KEYS)
      return state unless storable_timeline_cursor?(cursor, topic: topic, warnings: warnings)

      state.merge("backfill_cursor" => cursor, "backfill_stop_event_id" => stop_event_id).compact
    end

    # Returns the backfilled events and the topic state for the next sync.
    def continue_timeline_backfill(websocket, topic:, state:, max_pages:, warnings:)
      pass = collect_timeline_topic(
        websocket,
        topic: topic,
        known_newest_event_id: state["backfill_stop_event_id"],
        max_pages: max_pages,
        start_cursor: state["backfill_cursor"]
      )
      warnings.concat(pass.warnings)

      case pass.outcome
      when :finished, :caught_up
        [ pass.events, state.except(*TIMELINE_BACKFILL_KEYS) ]
      when :budget_exhausted
        next_state = start_timeline_backfill(state, topic: topic, cursor: pass.cursor, stop_event_id: state["backfill_stop_event_id"], warnings: warnings)
        [ pass.events, next_state ]
      else
        reason = pass.error&.class&.name&.demodulize || "pagination stalled"
        if pass.error.is_a?(Timeout) || pass.error.is_a?(TransientProviderError)
          raise TimelineBackfillInterrupted.new(
            "Trade Republic timeline backfill for #{topic} was interrupted",
            topic: topic,
            reason: reason,
            cursor: pass.cursor,
            events: pass.events
          )
        end

        [ pass.events, timeline_backfill_stopped(state, cursor: pass.cursor, topic: topic, reason: reason, warnings: warnings) ]
      end
    end

    # Resumes after the last page that was read. Abandoning counts failures
    # in a row at the same position, so a pass that moved forward starts the
    # count again.
    def timeline_backfill_stopped(state, cursor:, topic:, reason:, warnings:)
      return state.except(*TIMELINE_BACKFILL_KEYS) unless storable_timeline_cursor?(cursor, topic: topic, warnings: warnings)

      state = state.except("backfill_failures") if cursor != state["backfill_cursor"]
      timeline_backfill_failed(state.merge("backfill_cursor" => cursor), topic: topic, reason: reason, warnings: warnings)
    end

    # Keeps the cursor so the next sync retries the same page, until the
    # backfill has failed too often in a row.
    def timeline_backfill_failed(state, topic:, reason:, warnings:)
      failures = state["backfill_failures"].to_i + 1
      if failures >= MAX_TIMELINE_BACKFILL_FAILURES
        warnings << "timeline history backfill for #{topic} abandoned after #{failures} failed attempts (#{reason})"
        return state.except(*TIMELINE_BACKFILL_KEYS)
      end

      warnings << "timeline history backfill failed for #{topic} (#{reason})"
      state.merge("backfill_failures" => failures)
    end

    # Cursors come from the provider and are stored, so only short scalars
    # are kept.
    def storable_timeline_cursor?(cursor, topic:, warnings:)
      return true if (cursor.is_a?(String) || cursor.is_a?(Integer)) && cursor.to_s.length <= MAX_TIMELINE_CURSOR_LENGTH

      warnings << "timeline pagination cursor for #{topic} cannot be stored; older history is not imported"
      false
    end

    def collect_timeline_topic(websocket, topic:, known_newest_event_id:, max_pages:, start_cursor: nil)
      items = []
      warnings = []
      cursor = start_cursor
      seen_cursors = Set.new([ start_cursor ].compact)
      page_budget = [ max_pages, MAX_TIMELINE_PAGES ].min
      pages = 0
      outcome = :finished
      error = nil
      loop do
        if pages >= page_budget
          outcome = cursor.present? ? :budget_exhausted : :stalled
          break
        end
        payload = { type: topic }
        payload[:after] = cursor if cursor
        begin
          response = subscribe(websocket, payload)
        rescue Timeout, MalformedResponse, ProviderUnavailable => e
          # The newest pages fail as a whole; a backfill keeps what it read.
          raise if start_cursor.nil?

          error = e
          outcome = :failed
          break
        end
        page_items = response.is_a?(Hash) ? Array(response["items"]) : []
        items.concat(page_items)
        if known_newest_event_id.present? && page_items.any? { |item| item["id"].to_s == known_newest_event_id.to_s }
          outcome = :caught_up
          break
        end
        # An empty page only ends the topic when it carries no next cursor.
        next_cursor = response.dig("cursors", "after") if response.is_a?(Hash)
        break if next_cursor.blank?
        if seen_cursors.include?(next_cursor)
          warnings << "timeline pagination cursor repeated for #{topic}"
          outcome = :stalled
          break
        end
        seen_cursors << next_cursor
        cursor = next_cursor
        pages += 1
      end
      TimelinePass.new(
        events: items.map { |item| build_skeleton_event(item, warnings: warnings) },
        newest_event_id: items.filter_map { |item| item["id"].to_s.presence }.first,
        warnings: warnings,
        outcome: outcome,
        cursor: cursor,
        error: error
      )
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

    # Shared detail budget: reserve capacity for newly discovered trade and
    # dividend events, drain oldest stored incomplete / price-backfill trades
    # next, then spend any leftover on additional new events. Failed attempts
    # still consume budget so a bad event cannot starve the rest of the queue
    # forever within one sync. Stored dividends without their detail are
    # backfilled too.
    def enrich_timeline_details(websocket, events, enrich_events: [])
      warnings = []
      events = Array(events)
      new_candidates = events.select do |event|
        event["id"].present? &&
          (self.class.incomplete_trade_detail_event?(event) || self.class.dividend_detail_missing?(event))
      end
      new_ids = new_candidates.to_set { |event| event["id"].to_s }
      page_ids = events.filter_map { |event| event["id"].presence&.to_s }.to_set
      backlog_candidates = Array(enrich_events).select do |event|
        next false unless event.is_a?(Hash)

        item = event.stringify_keys
        next false if item["id"].blank?
        next false if new_ids.include?(item["id"].to_s)

        # A dividend on this sync's pages is handled there: a new one is
        # fetched above, and one that already has its details needs nothing.
        self.class.incomplete_trade_detail_event?(item) ||
          self.class.trade_detail_needs_price_backfill?(item) ||
          (self.class.dividend_detail_missing?(item) && !page_ids.include?(item["id"].to_s))
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
        fetched = nil
        begin
          detail = normalize_event_detail(
            subscribe(websocket, type: "timelineDetailV2", id: item["id"]),
            item: item
          )
          detail = detail&.slice(*DIVIDEND_DETAIL_KEYS) if category.to_s == DIVIDEND_DETAIL_CATEGORY
          fetched = build_normalized_event(item, category: category, detail: detail)
        rescue TransientProviderError, Timeout, RateLimited
          raise
        rescue Error
          warnings << "detail fetch failed for event #{item["id"]}"
        end

        if kind == :backfill
          result = fetched ? prefer_richer_event(item, fetched) : item
          detail_backfill_count += 1 if detail_backfill_improved?(item, result)
          if self.class.trade_detail_missing_price?(result)
            fetched = with_price_backfill_attempt(result)
          elsif self.class.incomplete_trade_detail_event?(result) || self.class.dividend_detail_missing?(result)
            fetched = with_detail_backfill_attempt(result)
          end
        end
        enriched_by_id[item["id"].to_s] = fetched if fetched
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

    def detail_backfill_improved?(before, after)
      return self.class.trade_detail_complete?(after) if self.class.incomplete_trade_detail_event?(before)

      self.class.trade_detail_missing_price?(before) && !self.class.trade_detail_missing_price?(after)
    end

    def with_price_backfill_attempt(event) = with_attempt_marker(event, PRICE_BACKFILL_ATTEMPTED_AT_KEY)

    def with_detail_backfill_attempt(event) = with_attempt_marker(event, DETAIL_BACKFILL_ATTEMPTED_AT_KEY)

    def with_attempt_marker(event, key)
      event = event.stringify_keys
      detail = (event["detail"] || {}).stringify_keys
      event.merge("detail" => detail.merge(key => Time.current.iso8601))
    end

    # Test/helper wrapper: enrich a raw timeline page without touching the list cursor.
    def resolve_details(websocket, items, newest_event_id, warnings)
      events = Array(items).map { |item| build_skeleton_event(item, warnings: warnings) }
      enriched, detail_warnings, = enrich_timeline_details(websocket, events, enrich_events: [])
      [ enriched, newest_event_id, warnings.concat(detail_warnings) ]
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
      rows = section_rows(collect_sections(raw))
      shares = find_row(rows, SHARE_TITLES)
      total = find_row(rows, TOTAL_TITLES)
      price_row = find_row(rows, PRICE_TITLES)
      fees = find_row(rows, FEE_TITLES)
      taxes = find_row(rows, TAX_TITLES)
      # A bond's nominal and quote sit in an untitled table inside an infoPage
      # bottom sheet. Only bond fields read it, so an unrelated nested table
      # can't fill in a share trade's price or total.
      bond_rows = rows + section_rows(collect_sections(raw, untitled_tables: true)) unless shares
      nominal = find_row(bond_rows, NOMINAL_TITLES) unless shares
      total ||= find_row(bond_rows, BOND_TOTAL_TITLES) if nominal
      quantity = decimal_from_row(shares) || decimal_from_row(nominal) || quantity_from_raw(raw)
      title = shares&.dig("title").to_s.downcase
      quantity = -quantity.abs if title.include?("entfernt") || title.include?("removed") || title.include?("gesendet") || title.include?("sent")
      subtitle = item&.dig("subtitle").to_s.downcase
      quantity = -quantity.abs if quantity && SELL_SUBTITLE_MARKERS.any? { |marker| subtitle.include?(marker) }
      amount = decimal_from_row(total)
      fee_amount = decimal_from_row(fees)
      tax_amount = decimal_from_row(taxes)
      price = decimal_from_row(price_row)
      quotation = decimal_from_row(find_row(bond_rows, QUOTATION_TITLES)) if nominal
      # Per unit of nominal, like a bond position's averageBuyIn: 92,67 % of
      # par is 0.9267.
      price ||= quotation / 100 if quotation
      dividend_per_share = decimal_from_row(find_row(rows, DIVIDEND_PER_SHARE_TITLES))
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
        "isin" => find_isin(item) || find_isin(raw) || find_logo_isin(raw),
        "name" => item&.dig("title") || find_asset_name(raw),
        "quantity" => decimal_string(quantity),
        "price" => decimal_string(price),
        "amount" => decimal_string(amount&.abs),
        "currency" => currency_from_row(total) || currency_from_row(shares) || currency_from_row(price_row),
        "fees" => decimal_string(fee_amount),
        "taxes" => decimal_string(tax_amount),
        "dividend_per_share" => decimal_string(dividend_per_share),
        "instrument_type" => (BOND_INSTRUMENT_TYPE if nominal)
      }.compact
    end

    def collect_sections(node, result = [], untitled_tables: false)
      case node
      when Hash
        section = untitled_tables ? node["type"] == "table" && !node.key?("title") : node.key?("title")
        result << node if section && node["data"].is_a?(Array)
        node.each_value { |value| collect_sections(value, result, untitled_tables:) }
      when Array then node.each { |value| collect_sections(value, result, untitled_tables:) }
      end
      result
    end

    def section_rows(sections) = sections.flat_map { |section| Array(section["data"]) }.select { |row| row.is_a?(Hash) }

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

    # Dividend details carry the ISIN only in the header logo path, e.g.
    # "logos/DE000A0F5UH1/v2".
    def find_logo_isin(raw)
      isin = nil
      walk(raw) do |value|
        isin ||= value[%r{\Alogos/([A-Z]{2}[A-Z0-9]{9}\d)/}, 1] if value.is_a?(String)
      end
      isin
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
