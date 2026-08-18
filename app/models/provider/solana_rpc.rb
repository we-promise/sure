# frozen_string_literal: true

# Keyless Solana data source backed by a public JSON-RPC endpoint.
#
# A dumb RPC client: the SPL token model and the mapping into an
# Onchain::Snapshot both live in Onchain::SolanaAdapter. Self-hosters, and anyone
# who outgrows the public endpoint's rate limit, can point this at their own node
# with SOLANA_RPC_URL.
class Provider::SolanaRpc
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_URL = "https://api.mainnet-beta.solana.com"

  # SPL tokens live in per-mint token accounts owned by the wallet. Both the
  # original token program and Token-2022 have to be asked.
  TOKEN_PROGRAM_IDS = [
    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
  ].freeze

  MIN_REQUEST_INTERVAL = 0.2
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  headers "Content-Type" => "application/json"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.url
    ENV["SOLANA_RPC_URL"].presence || DEFAULT_URL
  end

  # @return [Integer] lamports
  def get_balance(address)
    result = rpc("getBalance", [ address ])
    (result.is_a?(Hash) ? result["value"] : result).to_i
  end

  # @return [Array<Hash>] { pubkey:, mint:, raw_amount:, decimals: }
  def get_token_accounts(address)
    TOKEN_PROGRAM_IDS.flat_map do |program_id|
      result = rpc("getTokenAccountsByOwner", [ address, { programId: program_id }, { encoding: "jsonParsed" } ])
      accounts = result.is_a?(Hash) ? Array(result["value"]) : []

      accounts.filter_map do |account|
        info = account.dig("account", "data", "parsed", "info").to_h
        mint = info["mint"].to_s
        next if mint.blank?

        {
          pubkey: account["pubkey"],
          mint: mint,
          raw_amount: info.dig("tokenAmount", "amount").to_s,
          decimals: info.dig("tokenAmount", "decimals").to_i
        }
      end
    end
  end

  # @return [Array<Hash>] { signature:, block_time: }
  def get_signatures(pubkey, limit:)
    Array(rpc("getSignaturesForAddress", [ pubkey, { limit: limit } ])).map do |entry|
      { signature: entry["signature"], block_time: entry["blockTime"] }
    end
  end

  def get_transaction(signature)
    rpc("getTransaction", [ signature, { encoding: "jsonParsed", maxSupportedTransactionVersion: 0 } ])
  end

  private
    def rpc(method, params)
      attempts = 0
      body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json

      begin
        attempts += 1
        throttle_request
        handle_response(self.class.post(self.class.url, body: body))
      rescue RateLimitError => e
        raise if attempts > MAX_RETRIES

        Rails.logger.warn("Provider::SolanaRpc - rate limited (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
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
      raise RateLimitError, "Solana RPC rate limit exceeded" if response.code == 429
      raise ApiError, "Solana RPC error: #{response.code}" unless response.code.between?(200, 299)

      payload = response.parsed_response
      raise ApiError, "Unexpected Solana RPC response" unless payload.is_a?(Hash)
      raise ApiError, "Solana RPC error: #{payload.dig("error", "message")}" if payload["error"]

      payload["result"]
    end
end
