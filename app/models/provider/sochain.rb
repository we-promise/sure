# frozen_string_literal: true

# Litecoin, Dogecoin and Zcash data source backed by SoChain's v3 REST API.
#
# Works without a key, up to SoChain's keyless daily limit per IP. A family can
# add a key (https://sochain.com/dashboard) for a higher limit; it is sent as the
# API-KEY header. A dumb HTTP client: address validation and the mapping into an
# Onchain::Snapshot both live in Onchain::UtxoAdapter.
#
# Amounts arrive as decimal strings in whole coins and are kept as BigDecimal
# from the response onwards, so nothing is rounded through a float.
class Provider::Sochain
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://sochain.com/api/v3"
  # SoChain returns 10 transactions per page.
  PAGE_SIZE = 10
  DEFAULT_MAX_PAGES = 10
  MIN_REQUEST_INTERVAL = 0.25
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5
  # A Retry-After longer than this means the limit is spent for the day, not a
  # burst: waiting it out would hold a sync job for hours, so it fails instead.
  MAX_RETRY_AFTER = 10

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["SOCHAIN_URL"].presence || DEFAULT_BASE_URL
  end

  attr_reader :network

  # True when the walk stopped on the page budget rather than on the end of the
  # address's history.
  attr_reader :truncated

  # Detection reads on the request thread, so it sets its own timeout and retry
  # count, as Provider::Blockscout does.
  def initialize(network:, api_key: nil, max_pages: DEFAULT_MAX_PAGES, request_timeout: nil, max_retries: MAX_RETRIES)
    @network = network.to_s.upcase
    @api_key = api_key.to_s.strip.presence
    @max_pages = max_pages
    @request_timeout = request_timeout
    @max_retries = max_retries
    @truncated = false
  end

  # Confirmed balance plus the pending change from the mempool, which can be
  # negative.
  def get_balance(address)
    data = get_data("/balance/#{network}/#{encode(address)}")
    decimal(data["confirmed"]) + decimal(data["unconfirmed"])
  end

  # Number of transactions the address has taken part in. One request.
  def transaction_count(address)
    get_data("/transaction_counts/#{network}/#{encode(address)}")["total"].to_i
  end

  # Unconfirmed first, then newest first. Each entry is
  # { hash:, balance_change: BigDecimal, time: Time, block: Integer or nil }.
  def get_address_transactions(address)
    transactions = []
    page = []
    pages_read = 0
    @truncated = false

    while pages_read < @max_pages
      pages_read += 1
      page = Array(get_data("/transactions/#{network}/#{encode(address)}/#{pages_read}")["transactions"])
      transactions.concat(page.map { |transaction| parse_transaction(transaction) })
      break if page.size < PAGE_SIZE
    end

    @truncated = page.size >= PAGE_SIZE

    transactions
  end

  private
    attr_reader :api_key

    def parse_transaction(transaction)
      {
        hash: transaction["hash"].to_s,
        balance_change: decimal(transaction["balance_change"]),
        time: transaction["time"].present? ? Time.zone.at(transaction["time"].to_i) : nil,
        block: transaction["block"]&.to_i
      }
    end

    def decimal(value)
      BigDecimal(value.to_s.presence || "0")
    rescue ArgumentError
      raise ApiError, "SoChain returned an amount that is not a number"
    end

    def encode(address)
      ERB::Util.url_encode(address.to_s)
    end

    def get_data(path)
      body = get_json(path)
      raise ApiError, "SoChain returned an unexpected response" unless body.is_a?(Hash) && body["data"].is_a?(Hash)

      body["data"]
    end

    def get_json(path)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.get("#{self.class.base_url}#{path}", **request_options)) }
      rescue RateLimitError => e
        raise if attempts > @max_retries || @retry_after.to_f > MAX_RETRY_AFTER

        delay = @retry_after || RETRY_BASE_DELAY * (2**(attempts - 1))
        Rails.logger.warn("Provider::Sochain(#{network}) - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}")
        sleep(delay)
        retry
      end
    end

    def request_options
      options = { headers: { "Accept" => "application/json" } }
      options[:headers]["API-KEY"] = api_key if api_key.present?
      options[:timeout] = @request_timeout if @request_timeout
      options
    end

    def throttle_request
      @last_request_at ||= Time.at(0)
      remaining = MIN_REQUEST_INTERVAL - (Time.current - @last_request_at)
      sleep(remaining) if remaining.positive?
      @last_request_at = Time.current
    end

    def handle_response(response)
      @retry_after = nil

      case response.code
      when 200..299
        response.parsed_response
      when 401, 403
        raise AuthenticationError, "SoChain rejected the API key"
      when 400, 404
        raise InvalidAddressError, "SoChain rejected the address"
      when 429
        @retry_after = retry_after(response)
        raise RateLimitError, "SoChain rate limit exceeded"
      else
        raise ApiError, "SoChain API error: #{response.code}"
      end
    end

    # Seconds, when the header gives them as a number.
    def retry_after(response)
      value = response.headers&.[]("retry-after").to_s.strip
      value.match?(/\A\d+\z/) ? value.to_i : nil
    end
end
