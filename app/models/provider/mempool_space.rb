# frozen_string_literal: true

class Provider::MempoolSpace
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://mempool.space/api".freeze
  MIN_REQUEST_INTERVAL = 60.0 / 250.0
  DEFAULT_MAX_RETRIES = 3
  DEFAULT_RETRY_BASE_DELAY = 1.0
  ADDRESS_PATTERN = /\A(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,90}\z/i
  PAGE_SIZE = 25

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def initialize(max_retries: DEFAULT_MAX_RETRIES, retry_base_delay: DEFAULT_RETRY_BASE_DELAY)
    @max_retries = max_retries
    @retry_base_delay = retry_base_delay
  end

  def valid_address?(address)
    address.to_s.match?(ADDRESS_PATTERN)
  end

  def get_address(address)
    validate_address!(address)
    get_json("/address/#{address}")
  end

  def get_address_txs(address, max_pages: 20)
    validate_address!(address)

    transactions = []
    path = "/address/#{address}/txs"

    max_pages.times do
      batch = get_json(path)
      break if batch.blank?

      transactions.concat(batch)
      break if batch.size < PAGE_SIZE

      last_txid = batch.last&.dig("txid")
      raise ApiError, "Missing txid in paginated response" if last_txid.blank?

      path = "/address/#{address}/txs/chain/#{last_txid}"
    end

    transactions
  end

  def get_mempool_txs(address)
    validate_address!(address)
    get_json("/address/#{address}/txs/mempool")
  end

  def get_prices
    get_json("/v1/prices")
  end

  private
    def validate_address!(address)
      raise InvalidAddressError, "Invalid Bitcoin address" unless valid_address?(address)
    end

    def get_json(path)
      attempts = 0
      begin
        attempts += 1
        throttle_request
        response = self.class.get(path)
        handle_response(response)
      rescue RateLimitError => e
        raise if attempts > @max_retries
        delay = @retry_base_delay * (2**(attempts - 1))
        Rails.logger.warn "Provider::MempoolSpace - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}; sleeping #{delay}s"
        sleep(delay)
        retry
      end
    end

    def throttle_request
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = MIN_REQUEST_INTERVAL - elapsed
      sleep(sleep_time) if sleep_time.positive?
      @last_request_time = Time.current
    end

    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        parsed
      when 400, 404
        raise InvalidAddressError, parsed.to_s.presence || "Invalid Bitcoin address"
      when 429
        raise RateLimitError, "mempool.space rate limit exceeded"
      else
        raise ApiError, parsed.to_s.presence || "mempool.space API error: #{response.code}"
      end
    end
end
