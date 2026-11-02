# frozen_string_literal: true

# Keyless data source for Polygon's native POL staking. This is nothing like
# the existing `polygon` chain (Onchain::EvmAdapter reading the Polygon PoS
# L2 via Blockscout): staking/delegation is a contract on Ethereum mainnet
# (the StakeManagerProxy, per Polygon's own published contract registry) —
# the L2 chain itself has no idea who staked what, that bookkeeping lives on
# L1.
#
# Rather than hand-decode eth_call return data against that contract, Polygon
# publishes a keyless, dedicated REST API for exactly this
# (https://staking-api.polygon.technology/api/v2):
#   GET /delegators/{address} ->
#     {"success":true,"result":[{"bondedValidator":"9",
#       "stake":"534820520743891787497106", ...}], ...}
# `stake` is POL in wei (18 decimals), as a string. `result` is an array: one
# entry per validator the address has delegated to, summed by the adapter for
# the address's total staked position. It is paged by `limit`/`offset`, and
# `summary.total` counts only the page returned, so a short page is the only
# sign of the last one.
class Provider::PolygonStakingApi
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://staking-api.polygon.technology/api/v2"
  PAGE_LIMIT = 100
  MAX_PAGES = 5

  default_options.merge!({ timeout: 15 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["POLYGON_STAKING_API_URL"].presence || DEFAULT_BASE_URL
  end

  # Detection reads on the request thread and cannot afford the sync's patience,
  # same as Provider::SolanaRpc.
  def initialize(request_timeout: nil)
    @request_timeout = request_timeout
  end

  # Reads every page: a partial list would pass for a whole, lower stake.
  # @return [Array<Hash>] one entry per validator delegated to, each with a
  #   "stake" key (POL wei, string). Empty array for an address with no
  #   delegations - not an error, this API returns 200 with an empty result.
  def get_delegations(address)
    entries = []

    MAX_PAGES.times do |page|
      batch = get_page(address, offset: page * PAGE_LIMIT)
      entries.concat(batch)
      return entries if batch.size < PAGE_LIMIT
    end

    raise ApiError, "Polygon staking API returned more than #{MAX_PAGES} pages"
  end

  private
    def get_page(address, offset:)
      translate_transport_errors do
        response = self.class.get(
          "#{self.class.base_url}/delegators/#{ERB::Util.url_encode(address)}",
          **request_options(
            headers: { "Content-Type" => "application/json" },
            query: { limit: PAGE_LIMIT, offset: offset }
          )
        )
        raise RateLimitError, "Polygon staking API rate limit exceeded" if response.code == 429

        parsed = response.parsed_response
        raise ApiError, "Unexpected response from Polygon staking API" unless parsed.is_a?(Hash)
        raise ApiError, parsed["message"] || "Polygon staking API error" if parsed["success"] == false
        raise ApiError, "Polygon staking API returned no result" unless parsed["result"].is_a?(Array)

        parsed["result"]
      end
    end

    def request_options(**options)
      return options if @request_timeout.nil?

      options.merge(timeout: @request_timeout)
    end
end
