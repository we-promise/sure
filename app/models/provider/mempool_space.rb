# frozen_string_literal: true

# Keyless Bitcoin data source backed by mempool.space's REST API.
#
# A dumb HTTP client: address validation and the mapping into an
# Onchain::Snapshot both live in Onchain::BitcoinAdapter. Self-hosters can point
# this at their own instance with MEMPOOL_SPACE_URL.
class Provider::MempoolSpace
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://mempool.space/api"
  # mempool.space returns 25 confirmed transactions per page.
  PAGE_SIZE = 25
  DEFAULT_MAX_PAGES = 10
  MIN_REQUEST_INTERVAL = 0.25
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["MEMPOOL_SPACE_URL"].presence || DEFAULT_BASE_URL
  end

  # True when the walk stopped on the page budget rather than on the end of the
  # address's history, so the caller can say so instead of implying it read
  # everything.
  attr_reader :truncated

  def initialize(max_pages: DEFAULT_MAX_PAGES)
    @max_pages = max_pages
    @truncated = false
  end

  # Address summary: confirmed and mempool funded/spent totals.
  def get_address(address)
    get_json("/address/#{ERB::Util.url_encode(address)}")
  end

  # Confirmed transactions, newest first, plus anything still in the mempool.
  def get_address_transactions(address)
    encoded = ERB::Util.url_encode(address)
    page = Array(get_json("/address/#{encoded}/txs"))
    transactions = page.dup
    pages_read = 1
    @truncated = false

    while page.size >= PAGE_SIZE && pages_read < @max_pages
      last_txid = page.last["txid"]
      break if last_txid.blank?

      page = Array(get_json("/address/#{encoded}/txs/chain/#{last_txid}"))
      transactions.concat(page)
      pages_read += 1
    end

    @truncated = page.size >= PAGE_SIZE

    transactions
  end

  private
    def get_json(path)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.get("#{self.class.base_url}#{path}")) }
      rescue RateLimitError => e
        raise if attempts > MAX_RETRIES

        delay = RETRY_BASE_DELAY * (2**(attempts - 1))
        Rails.logger.warn("Provider::MempoolSpace - rate limited (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}")
        sleep(delay)
        retry
      end
    end

    def throttle_request
      @last_request_at ||= Time.at(0)
      remaining = MIN_REQUEST_INTERVAL - (Time.current - @last_request_at)
      sleep(remaining) if remaining.positive?
      @last_request_at = Time.current
    end

    def handle_response(response)
      case response.code
      when 200..299
        response.parsed_response
      when 400, 404
        raise InvalidAddressError, "mempool.space rejected the address"
      when 429
        raise RateLimitError, "mempool.space rate limit exceeded"
      else
        raise ApiError, "mempool.space API error: #{response.code}"
      end
    end
end
