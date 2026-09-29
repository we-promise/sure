require "base64"
require "digest"
require "etc"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "socket"
require "uri"

class Provider::TradeRepublicSession
  API_HOST = "api.traderepublic.com"
  API_ORIGIN = "https://#{API_HOST}"
  USER_AGENT = ENV.fetch(
    "TRADE_REPUBLIC_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36"
  )
  APP_VERSION = ENV.fetch("TRADE_REPUBLIC_APP_VERSION", "2.2631.13")
  WEB_PLATFORM = "web-pro"

  attr_reader :phone_number, :pin

  def initialize(phone_number:, pin:, session_blob: nil)
    @phone_number = phone_number.to_s
    @pin = pin.to_s
    @cookies = decode_cookies(session_blob)
    @device_info = nil
    @session_expires_at = Time.at(0)
  end

  def post(path, body:, headers: {})
    request(Net::HTTP::Post, path, body: body, headers: headers)
  end

  def get(path, headers: {}, body: nil)
    request(Net::HTTP::Get, path, body: body, headers: headers)
  end

  def cookies_blob
    JSON.generate(@cookies)
  end

  def cookie_header
    @cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
  end

  def login_headers
    browser_headers.merge(
      "X-TR-Device-Info" => device_info,
      "X-TR-App-Version" => APP_VERSION,
      "X-Tr-Platform" => WEB_PLATFORM
    )
  end

  def websocket_headers
    browser_headers.merge(
      "Cookie" => cookie_header,
      "Origin" => API_ORIGIN
    )
  end

  private

    def request(klass, path, body:, headers:)
      refresh_session_if_needed unless path == "/api/v1/auth/web/session"

      uri = URI.join(API_ORIGIN, path)
      request = klass.new(uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "application/json"
      browser_headers.each { |key, value| request[key] = value }
      request["Cookie"] = cookie_header if @cookies.any?
      headers.each { |key, value| request[key] = value }
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: timeout_seconds,
        read_timeout: timeout_seconds
      ) do |http|
        http.request(request)
      end
      update_cookies(response)
      response
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Provider::TradeRepublicClient::Timeout, "Trade Republic network request timed out: #{e.class}"
    rescue SocketError, Errno::ECONNRESET => e
      raise Provider::TradeRepublicClient::TransientProviderError, "Trade Republic network request failed: #{e.class}"
    end

    def refresh_session_if_needed
      return if Time.current < @session_expires_at

      response = request(Net::HTTP::Get, "/api/v1/auth/web/session", body: nil, headers: {})
      response.value
      @session_expires_at = 290.seconds.from_now
    rescue Net::HTTPClientException
      # Authentication endpoints may be called before a session exists.
      @session_expires_at = 290.seconds.from_now
    rescue Net::HTTPFatalError, Net::HTTPRetriableError => e
      raise Provider::TradeRepublicClient::TransientProviderError,
        "Trade Republic session refresh failed: #{e.class}"
    end

    def update_cookies(response)
      Array(response.get_fields("set-cookie")).each do |header|
        pair = header.split(";", 2).first
        name, value = pair.split("=", 2)
        @cookies[name] = value if name.present? && value.present?
      end
    end

    def browser_headers
      {
        "Origin" => API_ORIGIN,
        "Referer" => "#{API_ORIGIN}/",
        "Accept-Language" => "en-US,en;q=0.9",
        "Sec-Fetch-Dest" => "empty",
        "Sec-Fetch-Mode" => "cors",
        "Sec-Fetch-Site" => "same-site"
      }.tap do |headers|
        waf_token = ENV["TRADE_REPUBLIC_WAF_TOKEN"].presence
        headers["X-aws-waf-token"] = waf_token if waf_token
      end
    end

    def decode_cookies(blob)
      return {} if blob.blank?

      parsed = JSON.parse(blob)
      return parse_netscape_cookies(blob) unless parsed.is_a?(Hash)

      parsed.stringify_keys
    rescue JSON::ParserError
      parse_netscape_cookies(blob)
    end

    def parse_netscape_cookies(blob)
      blob.each_line.with_object({}) do |line, cookies|
        next if line.start_with?("#") || line.strip.blank?

        fields = line.strip.split("\t")
        cookies[fields[-2]] = fields[-1] if fields.length >= 7
      end
    end

    def device_info
      @device_info ||= Base64.strict_encode64(JSON.generate(
        stableDeviceId: stable_device_id,
        browser: "Chrome",
        browserVersion: USER_AGENT[/Chrome\/([\d.]+)/, 1].to_s,
        device: "Desktop",
        deviceType: "desktop",
        os: Etc.uname[:sysname].to_s,
        osVersion: Etc.uname[:release].to_s,
        timezone: Time.zone.tzinfo.name,
        timezoneOffset: -Time.zone.utc_offset / 60,
        screen: "1920x1080x24",
        preferredLanguages: [ "en" ],
        numberOfCores: Etc.nprocessors
      ))
    end

    def stable_device_id
      configured = ENV["TRADE_REPUBLIC_DEVICE_ID"].presence
      return Digest::SHA512.hexdigest(configured) if configured

      Digest::SHA512.hexdigest([ Socket.gethostname, RUBY_PLATFORM, Etc.uname[:machine], Etc.uname[:sysname] ].join("|"))
    end

    def timeout_seconds
      ENV.fetch("TRADE_REPUBLIC_HTTP_TIMEOUT_SECONDS", 30).to_i
    end
end
