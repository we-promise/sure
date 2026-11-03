# frozen_string_literal: true

# Keyless data source for a single Ethereum beacon-chain validator (native
# 32-ETH staking - not a liquid-staking token like stETH/rETH, those are
# already ordinary ERC-20s the existing `ethereum` chain picks up
# automatically). This reads the standardized Ethereum Beacon API
# (/eth/v1/beacon/...), not execution-layer JSON-RPC - a completely
# different API family from every other EVM adapter in this app.
#
# Every dedicated beacon-chain explorer API now requires a key. What's still
# free and keyless: PublicNode hosts the standard Beacon API REST spec
# directly, e.g.:
#   GET /eth/v1/beacon/states/head/validators/1 ->
#     {"data":{"index":"1","balance":"32001213479","status":"active_ongoing",
#       "validator":{"pubkey":"0xa1d1ad...", ...}}}
# and this endpoint also accepts the validator's own BLS pubkey in place of
# the index, returning identical data.
#
# `balance` is in Gwei (the Beacon API's convention), not wei - divide by 1e9
# for ETH, not 1e18.
class Provider::EthereumBeaconApi
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://ethereum-beacon-api.publicnode.com"

  default_options.merge!({ timeout: 15 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["ETHEREUM_BEACON_API_URL"].presence || DEFAULT_BASE_URL
  end

  # @param validator_id [String] a validator index ("1") or BLS pubkey
  #   ("0x" + 96 hex chars) - the Beacon API accepts either interchangeably.
  # @return [Hash, nil] {"index", "balance" (Gwei string), "status",
  #   "validator" => {"pubkey", ...}}, or nil if no such validator exists or
  #   the node rejects the id as malformed (400).
  def get_validator(validator_id)
    translate_transport_errors do
      response = self.class.get(
        "#{self.class.base_url}/eth/v1/beacon/states/head/validators/#{validator_id}",
        headers: { "Content-Type" => "application/json" }
      )

      return nil if response.code.in?([ 400, 404 ])
      raise RateLimitError, "Ethereum beacon API rate limit exceeded" if response.code == 429

      parsed = response.parsed_response
      raise ApiError, "Unexpected response from Ethereum beacon API" unless parsed.is_a?(Hash)

      data = parsed["data"]
      raise ApiError, "Ethereum beacon API returned no data" unless data.is_a?(Hash)

      data
    end
  end
end
