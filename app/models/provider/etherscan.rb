# frozen_string_literal: true

class Provider::Etherscan
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://api.etherscan.io/v2".freeze
  ETHEREUM_CHAIN_ID = "1"
  # Etherscan's free tier allows 3 req/s. Use a slightly larger interval than
  # the strict minimum (0.333s) to absorb clock jitter and network timing so we
  # don't trip the server-side counter at the edge.
  MIN_REQUEST_INTERVAL = 0.4
  DEFAULT_MAX_RETRIES = 3
  DEFAULT_RETRY_BASE_DELAY = 0.5
  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/
  PAGE_LIMIT = 1000
  MAX_PAGES = 20

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key

  def initialize(api_key:, max_retries: DEFAULT_MAX_RETRIES, retry_base_delay: DEFAULT_RETRY_BASE_DELAY)
    @api_key = api_key.to_s.strip
    raise AuthenticationError, "Etherscan API key is required" if @api_key.blank?
    @max_retries = max_retries
    @retry_base_delay = retry_base_delay
  end

  def valid_address?(address)
    address.to_s.match?(ADDRESS_PATTERN)
  end

  def get_native_balance(address)
    validate_address!(address)
    api_get(action: "balance", address: address, tag: "latest")
  end

  def get_normal_transactions(address, startblock: 0, sort: "asc")
    paged_api_get(action: "txlist", address: address, startblock: startblock, sort: sort)
  end

  def get_erc20_transfers(address, startblock: 0, sort: "asc")
    paged_api_get(action: "tokentx", address: address, startblock: startblock, sort: sort)
  end

  private
    def validate_address!(address)
      raise InvalidAddressError, "Invalid Ethereum address" unless valid_address?(address)
    end

    def paged_api_get(action:, address:, startblock:, sort:)
      validate_address!(address)

      results = []
      1.upto(MAX_PAGES) do |page|
        batch = api_get(
          action: action,
          address: address,
          startblock: startblock,
          endblock: 999_999_999,
          page: page,
          offset: PAGE_LIMIT,
          sort: sort
        )
        batch = [] if batch.is_a?(String) && batch.match?(/No transactions found/i)
        break if batch.blank?

        results.concat(Array(batch))
        break if batch.size < PAGE_LIMIT
      end

      results
    end

    def api_get(params)
      attempts = 0
      begin
        attempts += 1
        throttle_request
        response = self.class.get("/api", query: {
          apikey: api_key,
          chainid: ETHEREUM_CHAIN_ID,
          module: "account"
        }.merge(params))
        handle_response(response)
      rescue RateLimitError => e
        raise if attempts > @max_retries
        delay = @retry_base_delay * (2**(attempts - 1))
        Rails.logger.warn "Provider::Etherscan - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}; sleeping #{delay}s"
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
      raise RateLimitError, "Etherscan rate limit exceeded" if response.code == 429
      raise ApiError, "Etherscan API error: #{response.code}" unless response.code.between?(200, 299)
      raise ApiError, "Unexpected Etherscan response" unless parsed.is_a?(Hash)

      status = parsed["status"].to_s
      message = parsed["message"].to_s
      result = parsed["result"]

      return result if status == "1"
      return [] if message.match?(/No transactions found/i)

      error_text = result.presence || message.presence || "Etherscan API error"
      case error_text.to_s
      when /invalid api key|missing or unsupported chainid|apikey/i
        raise AuthenticationError, error_text
      when /rate limit|max rate|daily limit|temporarily unavailable/i
        raise RateLimitError, error_text
      else
        raise ApiError, error_text
      end
    end
end
