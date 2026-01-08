require "websocket-client-simple"
require "json"

class Provider::Traderepublic
  include HTTParty

  headers "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  HOST = "https://api.traderepublic.com".freeze
  WS_HOST = "wss://api.traderepublic.com".freeze
  WS_CONNECT_VERSION = "31".freeze

  ECHO_INTERVAL = 30 # seconds
  WS_CONNECTION_TIMEOUT = 10 # seconds
  SESSION_VALIDATION_TIMEOUT = 7 # seconds

  attr_reader :phone_number, :pin
  attr_accessor :session_token, :refresh_token, :raw_cookies, :process_id, :jsessionid

  def initialize(phone_number:, pin:, session_token: nil, refresh_token: nil, raw_cookies: nil)
    @phone_number = phone_number
    @pin = pin
    @session_token = session_token
    @refresh_token = refresh_token
    @raw_cookies = raw_cookies || []
    @process_id = nil
    @jsessionid = nil

    @ws = nil
    @subscriptions = {}
    @next_subscription_id = 1
    @echo_thread = nil
    @connected = false
    @mutex = Mutex.new
  end

  # Authentication - Step 1: Initial login to get processId
  def initiate_login
    payload = {
      phoneNumber: @phone_number,
      pin: @pin
    }
    
    Rails.logger.info "TradeRepublic: Initiating login for phone: #{@phone_number.gsub(/\d(?=\d{4})/, '*')}"
    Rails.logger.debug "TradeRepublic: Request payload: #{payload.to_json}"
    
    response = self.class.post(
      "#{HOST}/api/v1/auth/web/login",
      headers: default_headers,
      body: payload.to_json
    )

    Rails.logger.info "TradeRepublic: Login response status: #{response.code}"
    Rails.logger.debug "TradeRepublic: Login response body: #{response.body}"
    Rails.logger.debug "TradeRepublic: Login response headers: #{response.headers.inspect}"

    # Extract and store JSESSIONID cookie for subsequent requests
    if response.headers["set-cookie"]
      set_cookies = response.headers["set-cookie"]
      set_cookies = [set_cookies] unless set_cookies.is_a?(Array)
      set_cookies.each do |cookie|
        if cookie.start_with?("JSESSIONID=")
          @jsessionid = cookie.split(";").first
          Rails.logger.info "TradeRepublic: JSESSIONID extracted: #{@jsessionid}"
          break
        end
      end
    end

    handle_http_response(response)
  rescue => e
    Rails.logger.error "TradeRepublic: Initial login failed - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n") if e.respond_to?(:backtrace)
    raise TraderepublicError.new("Login initiation failed: #{e.message}", :login_failed)
  end

  # Authentication - Step 2: Verify device PIN
  def verify_device_pin(device_pin)
    raise TraderepublicError.new("No processId available", :invalid_state) unless @process_id

    url = "#{HOST}/api/v1/auth/web/login/#{@process_id}/#{device_pin}"
    headers = default_headers
    
    # Include JSESSIONID cookie if available
    if @jsessionid
      headers["Cookie"] = @jsessionid
      Rails.logger.info "TradeRepublic: Including JSESSIONID in verification request"
    end
    
    Rails.logger.info "TradeRepublic: Verifying device PIN for processId: #{@process_id}"
    Rails.logger.debug "TradeRepublic: Verification URL: #{url}"
    Rails.logger.debug "TradeRepublic: Verification headers: #{headers.inspect}"
    
    # IMPORTANT: Use POST, not GET!
    response = self.class.post(
      url,
      headers: headers
    )

    Rails.logger.info "TradeRepublic: PIN verification response status: #{response.code}"
    Rails.logger.debug "TradeRepublic: PIN verification response body: #{response.body}"
    Rails.logger.debug "TradeRepublic: PIN verification response headers: #{response.headers.inspect}"

    if response.success?
      extract_cookies_from_response(response)
      Rails.logger.info "TradeRepublic: Session token extracted: #{@session_token ? 'YES' : 'NO'}"
      Rails.logger.info "TradeRepublic: Refresh token extracted: #{@refresh_token ? 'YES' : 'NO'}"
      @session_token || raise(TraderepublicError.new("Session token not found after verification", :auth_failed))
    else
      handle_http_response(response)
    end
  rescue TraderepublicError
    raise
  rescue => e
    Rails.logger.error "TradeRepublic: Device PIN verification failed - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n") if e.respond_to?(:backtrace)
    raise TraderepublicError.new("PIN verification failed: #{e.message}", :verification_failed)
  end

  # Full login flow with device PIN callback
  def login(&device_pin_callback)
    return true if session_valid?

    # Step 1: Initiate login
    result = initiate_login
    @process_id = result["processId"]

    # Step 2: Get device PIN from user
    device_pin = device_pin_callback.call

    # Step 3: Verify device PIN
    verify_device_pin(device_pin)

    true
  rescue => e
    Rails.logger.error "TradeRepublic: Full login failed - #{e.message}"
    false
  end

  # Check if we have a valid session
  def session_valid?
    return false unless @session_token

    # We'll validate by trying to connect to WebSocket
    # This is a simple check - real validation would require a test subscription
    @session_token.present?
  end

  # Refresh session token using refresh_token
  def refresh_session
    unless @refresh_token
      Rails.logger.error "TradeRepublic: Cannot refresh session - no refresh token available"
      return false
    end

    Rails.logger.info "TradeRepublic: Refreshing session token"
    
    # Try the refresh endpoint first
    response = self.class.post(
      "#{HOST}/api/v1/auth/refresh",
      headers: default_headers.merge(cookie_header),
      body: { refreshToken: @refresh_token }.to_json
    )

    Rails.logger.info "TradeRepublic: Token refresh response status: #{response.code}"
    Rails.logger.debug "TradeRepublic: Token refresh response body: #{response.body}"

    if response.success?
      extract_cookies_from_response(response)
      Rails.logger.info "TradeRepublic: Session token refreshed: #{@session_token ? 'YES' : 'NO'}"
      return true
    end

    # If refresh endpoint doesn't work (404 or error), try alternate approach
    # Some APIs require re-authentication instead of refresh
    if response.code == 404 || response.code >= 400
      Rails.logger.warn "TradeRepublic: Refresh endpoint not available (#{response.code}), re-authentication required"
      return false
    end

    false
  rescue => e
    Rails.logger.error "TradeRepublic: Token refresh error - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n") if e.respond_to?(:backtrace)
    false
  end

  # WebSocket operations
  def connect_websocket
    raise "Already connected" if @ws && @ws.open?

    # Store reference to self for use in closures
    provider = self

    @ws = WebSocket::Client::Simple.connect(WS_HOST) do |ws|
      ws.on :open do
        Rails.logger.info "TradeRepublic: WebSocket opened"

        # Send connect message with proper configuration
        connect_msg = {
          locale: "fr",
          platformId: "webtrading",
          platformVersion: "safari - 18.3.0",
          clientId: "app.traderepublic.com",
          clientVersion: "3.151.3"
        }
        ws.send("connect #{WS_CONNECT_VERSION} #{connect_msg.to_json}")
        Rails.logger.info "TradeRepublic: Sent connect message, waiting for confirmation..."
      end

      ws.on :message do |msg|
        Rails.logger.debug "TradeRepublic: WebSocket received message: #{msg.data.to_s.inspect[0..200]}"
        
        # Mark as connected when we receive the "connected" response
        if msg.data.start_with?("connected")
          Rails.logger.info "TradeRepublic: WebSocket confirmed connected"
          provider.instance_variable_set(:@connected, true)
          provider.send(:start_echo_thread)
        end
        
        provider.send(:handle_websocket_message, msg.data)
      end

      ws.on :close do |e|
        code = e.respond_to?(:code) ? e.code : "unknown"
        reason = e.respond_to?(:reason) ? e.reason : "unknown"
        Rails.logger.info "TradeRepublic: WebSocket closed - Code: #{code}, Reason: #{reason}"
        provider.instance_variable_set(:@connected, false)
        thread = provider.instance_variable_get(:@echo_thread)
        thread&.kill
        provider.instance_variable_set(:@echo_thread, nil)
      end

      ws.on :error do |e|
        Rails.logger.error "TradeRepublic: WebSocket error - #{e.message}"
        provider.instance_variable_set(:@connected, false)
      end
    end

    # Wait for connection
    wait_for_connection
  end

  def disconnect_websocket
    return unless @ws

    if @echo_thread
      @echo_thread.kill
      @echo_thread = nil
    end

    if @ws.open?
      @ws.close
    end

    @ws = nil
    @connected = false
  end

  # Subscribe to a message type
  def subscribe(message_type, params = {}, &callback)
    raise "Not connected" unless @connected

    sub_id = @next_subscription_id
    @next_subscription_id += 1

    message = build_message(message_type, params)

    @mutex.synchronize do
      @subscriptions[sub_id] = {
        type: message_type,
        callback: callback,
        message: message
      }
    end

    send_subscription(sub_id, message)

    sub_id
  end

  # Unsubscribe from a subscription
  def unsubscribe(sub_id)
    @mutex.synchronize do
      @subscriptions.delete(sub_id)
    end

    @ws&.send("unsub #{sub_id}") if @connected
  end

  # Subscribe once (callback will be removed after first message)
  def subscribe_once(message_type, params = {})
    result = nil
    error = nil
    sub_id = subscribe(message_type, params) do |data|
      result = data
      unsubscribe(sub_id)
    end

    # Wait for result (with timeout)
    timeout = Time.now + SESSION_VALIDATION_TIMEOUT
    while result.nil? && Time.now < timeout
      sleep 0.1
      
      # Check if an error was stored in the subscription
      subscription = @subscriptions[sub_id]
      if subscription && subscription[:error]
        error = subscription[:error]
        unsubscribe(sub_id)
        break
      end
    end

    # Raise the error if one occurred
    raise error if error

    if result
      parsed = JSON.parse(result)
      
      # Handle double-encoded JSON (some TR responses are JSON strings containing JSON)
      if parsed.is_a?(String) && (parsed.start_with?("{") || parsed.start_with?("["))
        begin
          parsed = JSON.parse(parsed)
        rescue JSON::ParserError
          # Keep as string if it's not valid JSON
        end
      end
      parsed
    else
      nil
    end
  end

  # Helper: Get portfolio data
  def get_portfolio
    with_websocket_connection do
      subscribe_once("compactPortfolioByType")
    end
  end

  # Helper: Get cash data
  def get_cash
    with_websocket_connection do
      subscribe_once("cash")
    end
  end

  # Helper: Get available cash
  def get_available_cash
    with_websocket_connection do
      subscribe_once("availableCash")
    end
  end

  # Helper: Get timeline transactions (with automatic pagination)
  # @param since [Date, nil] Only fetch transactions after this date (for incremental sync)
  # Returns aggregated data from all pages in the same format as a single page response
  def get_timeline_transactions(since: nil)
    if since
      Rails.logger.info "TradeRepublic: Fetching timeline transactions since #{since} (incremental sync)"
    else
      Rails.logger.info "TradeRepublic: Fetching all timeline transactions (full sync)"
    end

    all_items = []
    page_num = 1
    cursor_after = nil
    max_pages = 100 # Safety limit to prevent infinite loops
    reached_since_date = false

    # Keep connection open for entire pagination
    begin
      connect_websocket

      loop do
        break if page_num > max_pages
        break if reached_since_date

        # Build subscription parameters
        params = cursor_after ? { after: cursor_after } : {}
        
        if page_num == 1
          Rails.logger.info "TradeRepublic: Fetching page #{page_num} (initial)"
        else
          Rails.logger.info "TradeRepublic: Fetching page #{page_num} (with cursor)"
        end

        # Subscribe and wait for response
        response_data = subscribe_once("timelineTransactions", params)
        
        unless response_data
          Rails.logger.warn "TradeRepublic: No response for page #{page_num}"
          break
        end

        # Extract items from this page
        items = response_data.dig("items") || []
        
        # If we have a 'since' date, filter items and check if we should stop
        if since
          items_to_add = []
          items.each do |item|
            # Parse timestamp (ISO 8601 format)
            timestamp_str = item.dig("timestamp")
            if timestamp_str
              item_date = DateTime.parse(timestamp_str).to_date
              
              if item_date > since
                items_to_add << item
              else
                # We've reached transactions older than 'since', stop pagination
                reached_since_date = true
                Rails.logger.info "TradeRepublic: Reached target date (#{since}), stopping pagination"
                break
              end
            else
              # No timestamp, include the item to be safe
              items_to_add << item
            end
          end
          
          all_items.concat(items_to_add)
          Rails.logger.info "TradeRepublic: Page #{page_num} - #{items_to_add.length}/#{items.length} new transactions (total: #{all_items.length})"
        else
          # No 'since' filter, add all items
          all_items.concat(items)
          Rails.logger.info "TradeRepublic: Page #{page_num} - #{items.length} transactions (total: #{all_items.length})"
        end

        # Stop if we reached the since date
        break if reached_since_date

        # Check if there's a next page
        cursors = response_data.dig("cursors") || {}
        cursor_after = cursors["after"]

        if cursor_after.nil? || cursor_after.empty?
          Rails.logger.info "TradeRepublic: No more pages available"
          break
        end

        page_num += 1
        
        # Small delay between requests
        sleep 0.3
      end

      if since && !reached_since_date && all_items.any?
        Rails.logger.info "TradeRepublic: Completed incremental sync - #{all_items.length} new transactions across #{page_num} page(s)"
      elsif since && !all_items.any?
        Rails.logger.info "TradeRepublic: No new transactions since #{since}"
      else
        Rails.logger.info "TradeRepublic: Completed full sync - #{all_items.length} total transactions across #{page_num} page(s)"
      end

      # Return in same format as original single-page response
      # but with all accumulated items
      {
        "items" => all_items,
        "cursors" => {}, # No cursor needed in final response
        "startingTransactionId" => nil
      }
    ensure
      disconnect_websocket
    end
  rescue => e
    Rails.logger.error "TradeRepublic: Failed to fetch timeline transactions - #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end

  # Helper: Get timeline detail
  def get_timeline_detail(id)
    with_websocket_connection do
      subscribe_once("timelineDetailV2", { id: id })
    end
  end

  # Helper: Get instrument details (name, description, etc.) by ISIN
  def get_instrument_details(isin)
    with_websocket_connection do
      subscribe_once("instrument", { id: isin })
    end
  end

  # Execute block with WebSocket connection
  def with_websocket_connection
    begin
      connect_websocket
      result = yield
      sleep 0.5 # Give time for any pending messages
      result
    rescue => e
      Rails.logger.error "TradeRepublic WebSocket error: #{e.message}"
      raise
    ensure
      disconnect_websocket
    end
  end

  private

  def default_headers
    {
      "Content-Type" => "application/json",
      "Accept" => "application/json",
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
      "Origin" => "https://app.traderepublic.com",
      "Referer" => "https://app.traderepublic.com/",
      "Accept-Language" => "en",
      "x-tr-platform" => "web",
      "x-tr-app-version" => "12.12.0"
    }
  end

  def cookie_header
    return {} if @raw_cookies.nil? || @raw_cookies.empty?
    
    # Join all cookies into a single Cookie header
    cookie_string = @raw_cookies.map do |cookie|
      # Extract just the name=value part before the first semicolon
      cookie.split(";").first
    end.join("; ")
    
    { "Cookie" => cookie_string }
  end

  def extract_cookies_from_response(response)
    # Extract Set-Cookie headers
    set_cookie_headers = response.headers["set-cookie"]

    if set_cookie_headers
      @raw_cookies = set_cookie_headers.is_a?(Array) ? set_cookie_headers : [ set_cookie_headers ]

      # Extract session and refresh tokens
      @session_token = extract_cookie_value("tr_session")
      @refresh_token = extract_cookie_value("tr_refresh")
    end
  end

  def extract_cookie_value(name)
    @raw_cookies.each do |cookie|
      match = cookie.match(/#{name}=([^;]+)/)
      return match[1] if match
    end
    nil
  end

  def wait_for_connection
    timeout = Time.now + WS_CONNECTION_TIMEOUT
    until @connected || Time.now > timeout
      sleep 0.1
    end

    raise TraderepublicError.new("WebSocket connection timeout", :connection_timeout) unless @connected
  end

  def start_echo_thread
    @echo_thread = Thread.new do
      loop do
        sleep ECHO_INTERVAL
        break unless @connected
        send_echo
      end
    end
  end

  def send_echo
    @ws&.send("echo #{Time.now.to_i * 1000}")
  rescue => e
    Rails.logger.warn "TradeRepublic: Failed to send echo - #{e.message}"
  end

  def handle_websocket_message(raw_message)
    return if raw_message.start_with?("echo") || raw_message.start_with?("connected")

    parsed = parse_websocket_payload(raw_message)
    return unless parsed

    sub_id = parsed[:subscription_id]
    json_string = parsed[:json_data]

    begin
      data = JSON.parse(json_string)
    rescue JSON::ParserError
      Rails.logger.error "TradeRepublic: Failed to parse WebSocket message JSON"
      return
    end

    # Check for authentication errors
    if data.is_a?(Hash) && data["errors"]
      auth_error = data["errors"].find { |err| err["errorCode"] == "AUTHENTICATION_ERROR" }
      if auth_error
        Rails.logger.error "TradeRepublic: Authentication error received - #{auth_error['errorMessage']}"
        # Store error for the subscription callback
        if sub_id && @subscriptions[sub_id]
          @subscriptions[sub_id][:error] = TraderepublicError.new(auth_error["errorMessage"] || "Unauthorized", :auth_failed)
        end
      end
    end

    return unless sub_id

    subscription = @subscriptions[sub_id]
    if subscription
      begin
        # If there's an error stored, raise it
        raise subscription[:error] if subscription[:error]
        
        subscription[:callback].call(json_string)
      rescue => e
        Rails.logger.error "TradeRepublic: Subscription callback error - #{e.message}"
        raise if e.is_a?(TraderepublicError) # Re-raise TraderepublicError to propagate auth failures
      end
    end
  end

  def parse_websocket_payload(raw_message)
    # Find the first occurrence of { or [
    start_index_obj = raw_message.index("{")
    start_index_arr = raw_message.index("[")
    
    start_index = if start_index_obj && start_index_arr
                    [start_index_obj, start_index_arr].min
                  elsif start_index_obj
                    start_index_obj
                  elsif start_index_arr
                    start_index_arr
                  else
                    nil
                  end

    return nil unless start_index

    id_part = raw_message[0...start_index].strip
    id_match = id_part.match(/\d+/)
    subscription_id = id_match ? id_match[0].to_i : nil

    json_data = raw_message[start_index..-1].strip

    { subscription_id: subscription_id, json_data: json_data }
  end

  def build_message(type, params = {})
    { type: type, token: @session_token }.merge(params)
  end

  def send_subscription(sub_id, message)
    payload = "sub #{sub_id} #{message.to_json}"
    @ws.send(payload)
  end

  def handle_http_response(response)
    Rails.logger.error "TradeRepublic: HTTP response code=#{response.code}, body=#{response.body}"

    case response.code
    when 200
      JSON.parse(response.body)
    when 400
      raise TraderepublicError.new("Bad request: #{response.body}", :bad_request)
    when 401
      raise TraderepublicError.new("Invalid credentials", :unauthorized)
    when 403
      raise TraderepublicError.new("Access forbidden", :forbidden)
    when 404
      raise TraderepublicError.new("Resource not found", :not_found)
    when 429
      raise TraderepublicError.new("Rate limit exceeded", :rate_limit_exceeded)
    when 500..599
      raise TraderepublicError.new("Server error: #{response.code}", :server_error)
    else
      raise TraderepublicError.new("Unexpected response: #{response.code}", :unexpected_response)
    end
  end
end
