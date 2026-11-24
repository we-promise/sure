# frozen_string_literal: true

# Read-only Revolut X client. Every call is a GET: the integration only ever
# reads balances, history and public market data, so nothing here can place
# or cancel an order even with a trading-enabled key.
class Provider::RevolutX
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://revx.revolut.com/api"
  # Signatures cover the path from /api on, not just the part after base_uri.
  SIGNED_PATH_PREFIX = URI(BASE_URL).path

  MAX_RATE_LIMIT_RETRIES = 3
  DEFAULT_RETRY_AFTER_MS = 1_000
  MAX_RETRY_AFTER_MS = 60_000

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  # private_key: an Ed25519 OpenSSL::PKey.
  def initialize(api_key:, private_key:)
    @api_key = api_key # pipelock:ignore user-supplied Revolut X credential kept in memory for signed requests
    @private_key = private_key # pipelock:ignore user-supplied Revolut X credential kept in memory for signed requests
  end

  def get_balances
    get("/1.0/balances")
  end

  def get_sub_accounts
    get("/1.0/sub-accounts")
  end

  # start_date/end_date: Times (or epoch milliseconds). Revolut X caps the
  # window at 30 days; next_cursor in the response metadata pages it.
  def get_transactions(start_date:, end_date:, cursor: nil, limit: 1900)
    params = { "start_date" => epoch_ms(start_date), "end_date" => epoch_ms(end_date) }
    params["cursor"] = cursor if cursor.present?
    params["limit"] = limit
    get("/1.0/transactions", params)
  end

  def get_currencies
    get("/1.0/public/configuration/currencies", signed: false)
  end

  def get_tickers
    get("/1.0/public/tickers", signed: false)
  end

  private

    attr_reader :api_key, :private_key

    def get(path, params = {}, signed: true)
      # Built once and sent as-is, so the query that was signed is
      # byte-identical to the one on the wire.
      query = URI.encode_www_form(params)
      url = query.empty? ? path : "#{path}?#{query}"
      attempts = 0

      loop do
        headers = signed ? signed_headers(path, query) : {}
        response = self.class.get(url, headers: headers)

        if response.code == 429
          attempts += 1
          raise RateLimitError, "Revolut X rate limit exceeded" if attempts > MAX_RATE_LIMIT_RETRIES

          sleep(retry_after_seconds(response))
          next
        end

        return handle_response(response)
      end
    end

    def signed_headers(path, query)
      timestamp = (Time.now.to_r * 1000).to_i.to_s
      message = "#{timestamp}GET#{SIGNED_PATH_PREFIX}#{path}#{query}"

      {
        "X-Revx-API-Key" => api_key,
        "X-Revx-Timestamp" => timestamp,
        "X-Revx-Signature" => Base64.strict_encode64(private_key.sign(nil, message))
      }
    end

    # Retry-After is in milliseconds on Revolut X, not seconds.
    def retry_after_seconds(response)
      value = response.headers["retry-after"].to_s
      ms = value.match?(/\A\d+\z/) ? value.to_i : DEFAULT_RETRY_AFTER_MS
      [ ms, MAX_RETRY_AFTER_MS ].min / 1000.0
    end

    def handle_response(response)
      case response.code
      when 200..299
        JSON.parse(response.body.to_s)
      when 401, 403
        raise AuthenticationError, "Revolut X rejected the API key or signature (#{response.code})"
      else
        raise ApiError, "Revolut X API request failed: #{response.code}"
      end
    rescue JSON::ParserError
      raise ApiError, "Malformed Revolut X API response"
    end

    def epoch_ms(value)
      value.is_a?(Integer) ? value : (value.to_time.to_r * 1000).to_i
    end
end
