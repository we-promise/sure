# frozen_string_literal: true

# Keyless data source for Avalanche's C-Chain (the EVM chain regular AVAX/
# token balances and transfers live on — completely separate from the
# P-Chain, where staking/delegation happens; see Provider::AvalanchePChain).
# Onchain::EvmAdapter already covers six EVM networks, but all of them go
# through Provider::Blockscout, and Avalanche's C-Chain has no Blockscout
# instance to point it at. Snowtrace (Avalanche's actual explorer) is an
# Etherscan-family site behind Cloudflare bot-protection that also blocks
# plain server-side requests, so it isn't usable keylessly either.
#
# What IS keylessly reachable: Avalanche's own public C-Chain RPC, standard
# Ethereum JSON-RPC.
#   eth_chainId -> 0xa86a (43114, Avalanche C-Chain mainnet)
#   eth_getBalance(address, "latest") -> wei-equivalent balance, 18 decimals,
#     same as every other EVM chain.
#
# No free, keyless way to enumerate ERC-20 token holdings or transfer history
# exists without a Blockscout/Etherscan-shaped indexer — this adapter reports
# native AVAX balance only, the same degrade Onchain::BitcoinAdapter and the
# P-Chain/Solana-stake/Ethereum-validator adapters already document for
# chains with no free indexer.
class Provider::AvalancheCChain
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://api.avax.network/ext/bc/C/rpc"

  default_options.merge!({ timeout: 15 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["AVALANCHE_CCHAIN_URL"].presence || DEFAULT_BASE_URL
  end

  # Detection reads on the request thread and cannot afford the sync's patience,
  # same as Provider::SolanaRpc.
  def initialize(request_timeout: nil)
    @request_timeout = request_timeout
  end

  # @return [String] balance in wei (18-decimal AVAX), as a hex string e.g. "0x1bc16d674ec80000"
  def get_balance(address)
    rpc("eth_getBalance", [ address, "latest" ])
  end

  # @return [String] the address's nonce (transactions it has sent), as a hex string
  def get_transaction_count(address)
    rpc("eth_getTransactionCount", [ address, "latest" ])
  end

  private
    def rpc(method, params)
      translate_transport_errors do
        response = self.class.post(
          self.class.base_url,
          **request_options(
            headers: { "Content-Type" => "application/json" },
            body: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
          )
        )
        raise RateLimitError, "Avalanche C-Chain rate limit exceeded" if response.code == 429

        parsed = response.parsed_response
        raise ApiError, "Unexpected response from Avalanche C-Chain node" unless parsed.is_a?(Hash)

        if parsed["error"].present?
          raise ApiError, parsed.dig("error", "message") || "Avalanche C-Chain RPC error"
        end

        result = parsed["result"]
        raise ApiError, "Avalanche C-Chain node returned no result" unless result.is_a?(String)

        result
      end
    end

    def request_options(**options)
      return options if @request_timeout.nil?

      options.merge(timeout: @request_timeout)
    end
end
