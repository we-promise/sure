require "bigdecimal"
require "json"
require "net/http"
require "time"
require "timeout"

# Restored-session reads only. Login, QR polling and authenticator challenges
# belong to the connection lifecycle. Every HTTP read may rotate cookies, so
# each successful response commits its cookie jar before another request or
# WebSocket subscription can use it. Cookie refresh is not assumed single-use:
# transient read failures must not create consumed-token recovery intents.
class Provider::TradeRepublicClient::IngestionClient
  MAX_RESPONSE_BYTES = 20.megabytes
  MAX_ROWS = 500
  MAX_MESSAGES = 100
  MAX_RETRY_AFTER_SECONDS = 300
  TOPICS = %w[timelineTransactions timelineActivityLog].freeze
  ORIGIN = "https://api.traderepublic.com"

  def initialize(credential_store:, user_agent: Provider::TradeRepublicSession::USER_AGENT,
    websocket_factory: ->(headers) { Provider::TradeRepublicWebsocket.new(headers: headers).connect })
    unless credential_store.respond_to?(:with_session_lock) && user_agent.is_a?(String) && !user_agent.match?(/[\r\n]/)
      raise Provider::TradeRepublicClient::ConfigurationError, "Trade Republic requires a durable credential session store"
    end
    @credential_store, @user_agent, @websocket_factory = credential_store, user_agent, websocket_factory
  end

  def get_account
    with_session { |account, _headers| account }
  end

  def get_cash
    with_socket do |socket, account|
      cash = subscribe(socket, type: "cash")
      available = begin
        subscribe(socket, type: "availableCash")
      rescue Provider::TradeRepublicClient::TransientProviderError
        raise
      rescue Provider::TradeRepublicClient::ProviderUnavailable
        nil
      end
      { "account" => account, "cash" => cash, "available_cash" => available }
    end
  end

  def get_portfolio
    with_socket do |socket, account|
      response = subscribe(socket, type: "compactPortfolioByType", secAccNo: account.fetch("securitiesAccountNumber"))
      rows = collection(response, "categories")
      positions = rows.flat_map { |row| collection(row, "positions") }
      raise Provider::TradeRepublicClient::MalformedResponse, "Trade Republic portfolio exceeds its position limit" if positions.size > MAX_ROWS
      { "account" => account, "portfolio" => response }
    end
  end

  # Quote failure is explicit evidence; the adapter decides whether a captured
  # prior quote can be used. No zero valuation is invented here.
  def get_price(instrument_id:, category_type:)
    id = identifier(instrument_id)
    exchanges = category_type == "cryptos" ? Provider::TradeRepublicClient::CRYPTO_TICKER_EXCHANGES : Provider::TradeRepublicClient::TICKER_EXCHANGES
    with_socket do |socket, account|
      attempts = []
      exchanges.each do |exchange|
        begin
          response = subscribe(socket, type: "ticker", id: "#{id}.#{exchange}")
          attempts << { "exchange" => exchange, "response" => response }
          if response.is_a?(Hash) && response["last"] && !response["last"].is_a?(Hash)
            raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic quote"
          end
          price = response.dig("last", "price") if response.is_a?(Hash)
          return { "account" => account, "price" => price, "attempts" => attempts } unless price.nil?
        rescue Provider::TradeRepublicClient::Timeout
          attempts << { "exchange" => exchange, "status" => "timeout" }
          break
        rescue Provider::TradeRepublicClient::TransientProviderError
          raise
        rescue Provider::TradeRepublicClient::ProviderUnavailable
          attempts << { "exchange" => exchange, "status" => "unavailable" }
        end
      end
      { "account" => account, "price" => nil, "attempts" => attempts }
    end
  end

  def get_timeline_page(topic:, cursor: nil)
    unless TOPICS.include?(topic) && (cursor.nil? || (cursor.is_a?(String) && cursor.present? && cursor.bytesize <= 16_384))
      raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic timeline request"
    end
    with_socket do |socket, account|
      response = subscribe(socket, { type: topic }.tap { |payload| payload[:after] = cursor if cursor })
      rows = collection(response, "items")
      cursors = response["cursors"]
      raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic timeline cursors" unless cursors.nil? || cursors.is_a?(Hash)
      after = cursors&.dig("after")
      unless after.nil? || after.is_a?(String)
        raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic timeline continuation"
      end
      after = after.presence
      if after && (!after.is_a?(String) || after.bytesize > 16_384 || after == cursor || rows.empty?)
        raise Provider::TradeRepublicClient::MalformedResponse, "Trade Republic timeline did not advance"
      end
      { "account" => account, "response" => response, "next_cursor" => after }
    end
  end

  def get_event_detail(event_id:)
    id = identifier(event_id)
    with_socket do |socket, account|
      { "account" => account, "response" => subscribe(socket, type: "timelineDetailV2", id: id) }
    end
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def with_session
      @credential_store.with_session_lock do |session|
        if session.refresh_pending?
          raise Provider::TradeRepublicClient::AuthenticationRequired, "Trade Republic session requires recovery"
        end
        credentials = session.credentials.stringify_keys
        if credentials["pending_login_state"].present? || credentials["session_blob"].blank?
          raise Provider::TradeRepublicClient::AuthenticationRequired, "Trade Republic session authorization is required"
        end
        unless session.respond_to?(:persist_session_credentials!)
          raise Provider::TradeRepublicClient::ConfigurationError, "Trade Republic requires ordinary session persistence"
        end
        cookies = decode_cookies(credentials.fetch("session_blob"))
        credentials, cookies, = authenticated_get(session, credentials, cookies, "/api/v1/auth/web/session")
        credentials, cookies, account = authenticated_get(session, credentials, cookies, "/api/v2/auth/account")
        identifier(account["securitiesAccountNumber"])
        yield account, headers(credentials).merge("Cookie" => cookie_header(cookies))
      end
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      raise Provider::TradeRepublicClient::ConfigurationError, "Invalid Trade Republic credential session", cause: nil
    end

    def authenticated_get(session, credentials, cookies, path)
      begin
        uri = URI("#{ORIGIN}#{path}")
        request = Net::HTTP::Get.new(uri)
        headers(credentials).merge("Cookie" => cookie_header(cookies)).each { |key, value| request[key] = value }
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 30, max_retries: 0) { |http| http.request(request) }
        case response.code.to_i
        when 200..299
          Array(response.get_fields("set-cookie")).each do |header|
            pair = header.split(";", 2).first
            name, value = pair.split("=", 2)
            validate_cookie!(name, value)
            value.empty? ? cookies.delete(name) : cookies[name] = value
          end
          values = credentials.merge("session_blob" => JSON.generate(cookies))
          session.persist_session_credentials!(values)
          # /session is permitted to have an empty successful body. The account
          # response must always contain a valid JSON object.
          body = response.body.to_s
          parsed = body.empty? && path.end_with?("/session") ? {} : parse_payload(body)
          [ values, cookies, parsed ]
        when 401, 403
          code = begin
            value = parse_payload(response.body.to_s)
            value["errorCode"] || value.dig("errors", 0, "errorCode") if value.is_a?(Hash)
          rescue Provider::TradeRepublicClient::MalformedResponse
            nil
          end
          if %w[WAF_REQUIRED MISSING_REQUIRED_HEADER].include?(code)
            raise Provider::TradeRepublicClient::WafRequired, "Trade Republic requires browser authorization"
          end
          raise Provider::TradeRepublicClient::AuthenticationRequired, "Trade Republic session authorization is required"
        when 408
          raise Provider::TradeRepublicClient::Timeout, "Trade Republic session read timed out"
        when 429
          raise Provider::TradeRepublicClient::RateLimited.new("Trade Republic session was rate limited", retry_after: retry_after(response))
        when 500, 502, 503, 504
          raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic session is temporarily unavailable"
        else
          raise Provider::TradeRepublicClient::ProviderUnavailable, "Trade Republic session read failed"
        end
      rescue Provider::AccountData::StaleWriter, Provider::AccountData::CredentialStore::ReauthorizationRequired => error
        # Ownership and uncertain-grant denials are not transport outages. Keep
        # their classification so coordinators cannot retry through a lost lease.
        raise error.class, "Trade Republic credential access was refused", cause: nil
      rescue Provider::TradeRepublicClient::RateLimited => error
        raise Provider::TradeRepublicClient::RateLimited.new("Trade Republic session read failed", retry_after: error.retry_after), cause: nil
      rescue StandardError => error
        klass = case error
        when Net::ReadTimeout, Net::OpenTimeout
          Provider::TradeRepublicClient::Timeout
        when Provider::TradeRepublicClient::AuthenticationRequired, Provider::TradeRepublicClient::WafRequired,
          Provider::TradeRepublicClient::Timeout, Provider::TradeRepublicClient::TransientProviderError, Provider::TradeRepublicClient::MalformedResponse
          error.class
        else
          Provider::TradeRepublicClient::ProviderUnavailable
        end
        raise klass, "Trade Republic session read failed", cause: nil
      end
    end

    def with_socket
      with_session do |account, request_headers|
        socket = @websocket_factory.call(request_headers)
        begin
          socket.send_text("connect 31 #{JSON.generate(Provider::TradeRepublicClient::CONNECT_MESSAGE)}")
          unless receive(socket) == "connected"
            raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic WebSocket handshake was rejected"
          end
          yield socket, account
        ensure
          socket.close
        end
      end
    rescue Provider::TradeRepublicClient::RateLimited => error
      raise Provider::TradeRepublicClient::RateLimited.new("Trade Republic account read failed", retry_after: error.retry_after), cause: nil
    rescue Provider::TradeRepublicClient::Error => error
      # Preserve useful error classes, without retaining transport exception text.
      raise error.class, "Trade Republic account read failed", cause: nil
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic transport failed", cause: nil
    end

    def subscribe(socket, payload)
      @subscription_id = @subscription_id.to_i + 1
      id = @subscription_id
      socket.send_text("sub #{id} #{JSON.generate(payload)}")
      MAX_MESSAGES.times do
        message = receive(socket)
        unless message.is_a?(String) && message.bytesize <= MAX_RESPONSE_BYTES
          raise Provider::TradeRepublicClient::MalformedResponse, "Trade Republic subscription exceeds its response limit"
        end
        response_id, code, data = message.split(" ", 3)
        next unless response_id == id.to_s
        case code
        when "A" then return parse_payload(data)
        when "D" then raise Provider::TradeRepublicClient::MalformedResponse, "Trade Republic delta has no captured base"
        when "E", "C" then raise Provider::TradeRepublicClient::ProviderUnavailable, "Trade Republic subscription is unavailable"
        end
      end
      raise Provider::TradeRepublicClient::MalformedResponse, "Trade Republic subscription exceeded its message limit"
    ensure
      begin
        socket.send_text("unsub #{id}") if id
      rescue IOError, Provider::TradeRepublicClient::Error
        nil
      end
    end

    def headers(credentials)
      { "User-Agent" => @user_agent, "Accept" => "application/json", "Origin" => ORIGIN,
        "Referer" => "#{ORIGIN}/", "Accept-Language" => "en-US,en;q=0.9",
        "Sec-Fetch-Dest" => "empty", "Sec-Fetch-Mode" => "cors", "Sec-Fetch-Site" => "same-site" }.tap do |values|
        token = credentials["waf_token"]
        if token.present?
          raise ArgumentError unless token.is_a?(String) && !token.match?(/[\r\n]/)
          values["X-aws-waf-token"] = token
        end
      end
    end

    def receive(socket)
      ::Timeout.timeout(30, ::Timeout::Error) { socket.receive }
    rescue ::Timeout::Error
      raise Provider::TradeRepublicClient::Timeout, "Trade Republic subscription timed out", cause: nil
    end

    def retry_after(response)
      raw = response["Retry-After"]
      return if raw.nil?
      return :invalid unless raw.is_a?(String) && raw.bytesize <= 128
      raw = raw.strip
      delay = raw.match?(/\A[0-9]+\z/) ? Integer(raw, 10) : Time.httpdate(raw) - Time.current
      return :invalid unless delay.finite? && delay.positive? && delay <= MAX_RETRY_AFTER_SECONDS
      delay.ceil
    rescue ArgumentError
      # Keep absent and invalid headers distinct without retaining provider text.
      :invalid
    end

    def decode_cookies(blob)
      raise ArgumentError unless blob.is_a?(String) && blob.bytesize <= 1.megabyte
      parsed = begin
        JSON.parse(blob)
      rescue JSON::ParserError
        blob.each_line.with_object({}) do |line, result|
          # HttpOnly Netscape cookies begin with a comment-looking prefix.
          line = line.delete_prefix("#HttpOnly_")
          next if line.start_with?("#") || line.strip.empty?
          fields = line.chomp.split("\t", -1)
          raise ArgumentError unless fields.size == 7 && [ "api.traderepublic.com", ".traderepublic.com", "traderepublic.com" ].include?(fields[0])
          result[fields[5]] = fields[6]
        end
      end
      raise ArgumentError unless parsed.is_a?(Hash) && parsed.any? && parsed.size <= 100
      parsed.each { |key, value| validate_cookie!(key, value) }
      parsed
    end

    def validate_cookie!(name, value)
      unless name.is_a?(String) && name.match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/) &&
          value.is_a?(String) && !value.match?(/[\x00-\x20\x7f;,]/)
        raise ArgumentError
      end
    end

    def cookie_header(cookies)
      cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    def identifier(value)
      unless (value.is_a?(String) || value.is_a?(Integer)) && value.to_s.present? && value.to_s.bytesize <= 512 && !value.to_s.match?(/[[:cntrl:]]/)
        raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic identifier"
      end
      value.to_s
    end

    def parse_payload(body)
      raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_RESPONSE_BYTES
      response = JSON.parse(body, decimal_class: BigDecimal)
      raise ArgumentError unless response.is_a?(Hash) || response.is_a?(Array)
      response
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic response", cause: nil
    end

    def collection(response, key)
      rows = response.is_a?(Hash) ? response[key] : nil
      unless rows.is_a?(Array) && rows.size <= MAX_ROWS && rows.all? { |row| row.is_a?(Hash) }
        raise Provider::TradeRepublicClient::MalformedResponse, "Invalid Trade Republic collection"
      end
      rows
    end
end
