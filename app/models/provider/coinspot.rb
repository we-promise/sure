# frozen_string_literal: true

class Provider::Coinspot
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class NonceError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://www.coinspot.com.au"
  READ_ONLY_PREFIX = "/api/v2/ro"

  # CoinSpot's order-history endpoints default to 200 records per response
  # when no `limit` is given, and cap at 500 -- always request the max so a
  # single response is less likely to silently truncate an active window.
  MAX_ORDER_HISTORY_LIMIT = 500

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  # A client for CoinSpot's read-only v2 API, signing every request with the
  # given credentials. `nonce_generator` defaults to a millisecond
  # timestamp, but callers syncing from multiple processes/threads should
  # supply a monotonic one (e.g. CoinspotItem#next_nonce!) since CoinSpot
  # rejects a nonce that doesn't strictly increase.
  def initialize(api_key:, api_secret:, nonce_generator: nil)
    @api_key = api_key # pipelock:ignore user-supplied CoinSpot credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied CoinSpot credential kept in memory for signed requests
    @nonce_generator = nonce_generator || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond).to_i }
  end

  # Confirms the credentials are valid and the API is reachable.
  def status
    read_only_post("/status")
  end

  # Current balances for every asset held on the account.
  def get_balances
    read_only_post("/my/balances")
  end

  # Completed buy/sell order history, optionally scoped to a date range.
  def get_order_history(startdate: nil, enddate: nil, limit: MAX_ORDER_HISTORY_LIMIT)
    read_only_post("/my/orders/completed", date_params(startdate: startdate, enddate: enddate).merge("limit" => limit))
  end

  # Completed market-order history -- a fallback CoinSpot exposes separately
  # from the primary order-history endpoint for market-type orders.
  def get_market_order_history(startdate: nil, enddate: nil, limit: MAX_ORDER_HISTORY_LIMIT)
    read_only_post("/my/orders/market/completed", date_params(startdate: startdate, enddate: enddate).merge("limit" => limit))
  end

  # On-chain send/receive transaction history.
  def get_send_receive_history(startdate: nil, enddate: nil)
    read_only_post("/my/sendreceive", date_params(startdate: startdate, enddate: enddate))
  end

  # AUD deposit history.
  def get_deposit_history(startdate: nil, enddate: nil)
    read_only_post("/my/deposits", date_params(startdate: startdate, enddate: enddate))
  end

  # AUD withdrawal history.
  def get_withdrawal_history(startdate: nil, enddate: nil)
    read_only_post("/my/withdrawals", date_params(startdate: startdate, enddate: enddate))
  end

  private

    attr_reader :nonce_generator

    # Builds the startdate/enddate request params CoinSpot expects
    # (YYYY-MM-DD), omitting either when not given.
    def date_params(startdate:, enddate:)
      {}.tap do |params|
        params["startdate"] = startdate.to_date.to_s if startdate.present?
        params["enddate"] = enddate.to_date.to_s if enddate.present?
      end
    end

    # Posts a signed request to CoinSpot's read-only API and returns the
    # parsed, successful response body, raising a classified error otherwise.
    def read_only_post(path, params = {})
      request_params = { "nonce" => nonce_generator.call }.merge(stringify_params(params))
      body = JSON.generate(request_params)

      response = self.class.post(
        "#{READ_ONLY_PREFIX}#{path}",
        body: body,
        headers: {
          "Content-Type" => "application/json",
          "key" => api_key,
          "sign" => sign(body)
        }
      )

      handle_response(response)
    end

    # Stringifies every param key and value for a stable, predictable JSON body.
    def stringify_params(params)
      params.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value.to_s }
    end

    # HMAC-SHA512 signature of the request body, as CoinSpot's API requires.
    def sign(body)
      OpenSSL::HMAC.hexdigest("sha512", api_secret, body)
    end

    # Parses and validates a CoinSpot response, raising a classified error
    # for a non-2xx status, a non-JSON-object body, or a JSON body whose own
    # "status" field reports "error".
    def handle_response(response)
      parsed = response.parsed_response

      unless response.code.between?(200, 299)
        message = (parsed["message"].presence if parsed.is_a?(Hash)) || "CoinSpot API request failed: #{response.code}"
        raise classified_error(message, http_status: response.code)
      end

      raise ApiError, "Malformed CoinSpot API response" unless parsed.is_a?(Hash)

      status = parsed["status"].to_s.downcase
      raise classified_error(parsed["message"].presence || "CoinSpot API request failed") if status == "error"

      parsed
    end

    # Classifies both by the response body's message (CoinSpot's normal error
    # shape, even on a 2xx status) and by HTTP status (401/403), since a
    # non-2xx credential/permission failure may arrive with a body CoinSpot
    # doesn't word the same way as its 2xx error responses. Either signal
    # matching is enough to classify -- the syncer only rescues
    # AuthenticationError/PermissionError to mark the item as needing updated
    # credentials, so a missed classification here silently falls through to
    # the generic failure path instead.
    def classified_error(message, http_status: nil)
      return AuthenticationError.new(message) if http_status == 401
      return PermissionError.new(message) if http_status == 403

      case message
      when /invalid key|invalid signature|authentication|unauthori[sz]ed/i
        AuthenticationError.new(message)
      when /permission|read.only|read only/i
        PermissionError.new(message)
      when /nonce/i
        NonceError.new(message)
      when /rate|too many|limit/i
        RateLimitError.new(message)
      else
        ApiError.new(message)
      end
    end
end
