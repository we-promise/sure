# frozen_string_literal: true

# Keyless Cosmos Hub data source backed by a public Cosmos SDK REST (LCD)
# endpoint. Self-hosters can point it at their own node with COSMOS_REST_URL.
class Provider::CosmosRest
  include HTTParty
  include Provider::HttpTransport
  include Provider::RateLimitable
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://cosmos-rest.publicnode.com"
  # Delegations and unbondings are one entry per validator.
  PAGE_LIMIT = 200
  MAX_PAGES = 5
  MIN_REQUEST_INTERVAL = 0.25
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["COSMOS_REST_URL"].presence || DEFAULT_BASE_URL
  end

  # @return [String] the spendable amount of `denom`, in its smallest unit
  def balance(address, denom)
    amount = get_json("/cosmos/bank/v1beta1/balances/#{encode(address)}/by_denom", denom: denom).dig("balance", "amount")
    raise ApiError, "Cosmos REST returned no balance" if amount.nil?

    amount
  end

  def delegations(address)
    all_pages("/cosmos/staking/v1beta1/delegations/#{encode(address)}", "delegation_responses")
  end

  def unbonding_delegations(address)
    all_pages("/cosmos/staking/v1beta1/delegators/#{encode(address)}/unbonding_delegations", "unbonding_responses")
  end

  private
    # Reads every page: a partial list would pass for a whole, lower balance.
    def all_pages(path, key)
      entries = []
      next_key = nil

      MAX_PAGES.times do
        body = get_json(path, { "pagination.limit": PAGE_LIMIT, "pagination.key": next_key }.compact)
        raise ApiError, "Cosmos REST returned no #{key}" unless body.key?(key)

        entries.concat(Array(body[key]))
        next_key = body.dig("pagination", "next_key").presence
        return entries if next_key.nil?
      end

      raise ApiError, "Cosmos REST returned more than #{MAX_PAGES} pages"
    end

    def encode(address)
      ERB::Util.url_encode(address)
    end

    def get_json(path, query = {})
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.get("#{self.class.base_url}#{path}", query: query)) }
      rescue RateLimitError => e
        raise if attempts > MAX_RETRIES

        Rails.logger.warn("Provider::CosmosRest - rate limited (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
        retry
      end
    end

    def handle_response(response)
      case response.code
      when 200..299
        body = response.parsed_response
        raise ApiError, "Cosmos REST returned an unexpected body" unless body.is_a?(Hash)

        body
      when 400
        raise InvalidAddressError, "Cosmos REST rejected the address"
      when 429
        raise RateLimitError, "Cosmos REST rate limit exceeded"
      else
        raise ApiError, "Cosmos REST API error: #{response.code}"
      end
    end
end
