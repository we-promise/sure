# frozen_string_literal: true

# Keyless data source for Avalanche's P-Chain (where staking/delegation
# happens — distinct from the EVM-compatible C-Chain that Onchain::EvmAdapter
# already handles). Talks to Avalanche's public node JSON-RPC API directly;
# there is no Blockscout/mempool.space-style REST explorer for the P-Chain.
#
#   platform.getBalance {addresses: [...]} -> {balance, unlocked,
#     lockedStakeable, lockedNotStakeable, ...} - everything sitting in P-Chain
#     UTXOs, whether or not it's currently eligible/locked for staking.
#   platform.getStake {addresses: [...]} -> {staked, ...} - the amount from
#     these addresses currently bonded in an active validation or delegation.
# Both are in nAVAX (1 AVAX = 10^9 nAVAX — the P-Chain's native 9-decimal unit,
# distinct from the 18-decimal wrapped AVAX used on the EVM C-Chain).
class Provider::AvalanchePChain
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://api.avax.network/ext/bc/P"

  default_options.merge!({ timeout: 15 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["AVALANCHE_PCHAIN_URL"].presence || DEFAULT_BASE_URL
  end

  # @return [Hash] {"balance" => nAVAX_string, "unlocked" => ..., ...}
  def get_balance(address)
    rpc("platform.getBalance", { addresses: [ address ] })
  end

  # @return [Hash] {"staked" => nAVAX_string, ...}
  def get_stake(address)
    rpc("platform.getStake", { addresses: [ address ] })
  end

  private
    def rpc(method, params)
      translate_transport_errors do
        response = self.class.post(
          self.class.base_url,
          headers: { "Content-Type" => "application/json" },
          body: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
        )

        parsed = response.parsed_response
        raise ApiError, "Unexpected response from Avalanche P-Chain node" unless parsed.is_a?(Hash)

        if parsed["error"].present?
          raise ApiError, parsed.dig("error", "message") || "Avalanche P-Chain RPC error"
        end

        result = parsed["result"]
        raise ApiError, "Avalanche P-Chain node returned no result" unless result.is_a?(Hash)

        result
      end
    end
end
