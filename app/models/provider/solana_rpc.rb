# frozen_string_literal: true

# Keyless Solana data provider backed by a public JSON-RPC endpoint.
#
# Reads native SOL + SPL token balances, plus best-effort transaction history
# (signed net amounts derived from each transaction's pre/post balances). No
# API key required; the endpoint is overridable via ENV for self-hosters.
class Provider::SolanaRpc
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  TOKEN_PROGRAM_ID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  TOKEN_2022_PROGRAM_ID = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
  LAMPORTS_PER_SOL = 1_000_000_000.to_d
  ADDRESS_PATTERN = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/
  SIGNATURES_PER_SOURCE = 50
  MAX_TRANSACTIONS = 60
  SOL_DUST = BigDecimal("0.0001")

  # Well-known SPL mints → display metadata.
  KNOWN_MINTS = {
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB" => { symbol: "USDT", name: "Tether USD" },
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" => { symbol: "USDC", name: "USD Coin" }
  }.freeze

  def self.rpc_url
    ENV.fetch("SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com")
  end

  headers "User-Agent" => "Sure On-Chain Wallets", "Content-Type" => "application/json"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def valid_address?(address)
    address.to_s.match?(ADDRESS_PATTERN)
  end

  # @return [String] native SOL balance in lamports
  def get_native_balance(address)
    validate_address!(address)
    result = rpc("getBalance", [ address ])
    (result.is_a?(Hash) ? result["value"] : result).to_s
  end

  # @return [Array<Hash>] [{ mint:, symbol:, name:, decimals:, raw_amount:, ui_amount: }]
  def get_token_balances(address)
    validate_address!(address)
    token_accounts(address).filter_map do |account|
      info = account.dig("account", "data", "parsed", "info") || {}
      mint = info["mint"].to_s
      amount = info.dig("tokenAmount", "amount").to_s
      decimals = info.dig("tokenAmount", "decimals").to_i
      next if mint.blank? || amount.blank? || amount == "0"

      known = KNOWN_MINTS[mint]
      {
        mint: mint,
        symbol: known&.dig(:symbol) || mint.first(6),
        name: known&.dig(:name) || "SPL #{mint.first(4)}…#{mint.last(4)}",
        decimals: decimals,
        raw_amount: amount,
        ui_amount: BigDecimal(amount) / (10.to_d**decimals)
      }
    end
  end

  # Best-effort transaction history (native SOL + SPL), in the shape the
  # importer/processor expect: { "hash" => sig, "onchain_amount" => signed,
  # "timeStamp" => unix, "mint" => mint? }.
  # @return [Array<Hash>]
  def get_transactions(address)
    validate_address!(address)
    pubkeys = [ address, *token_account_pubkeys(address) ].uniq
    signatures = {}
    pubkeys.each { |pk| fetch_signatures(pk).each { |s| signatures[s[:signature]] ||= s[:block_time] } }

    signatures.keys.first(MAX_TRANSACTIONS).flat_map do |sig|
      tx = get_transaction(sig)
      tx ? parse_transaction(tx, address, signatures[sig]) : []
    rescue Error
      []
    end
  end

  private
    def validate_address!(address)
      raise InvalidAddressError, "Invalid Solana address" unless valid_address?(address)
    end

    # Memoized per address: both get_token_balances and get_transactions need
    # this, so caching avoids duplicate getTokenAccountsByOwner RPC calls in a
    # single sync (which matters on rate-limited public RPCs).
    def token_accounts(address)
      @token_accounts ||= {}
      @token_accounts[address] ||= begin
        [ TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID ].flat_map do |program_id|
          result = rpc("getTokenAccountsByOwner", [ address, { programId: program_id }, { encoding: "jsonParsed" } ])
          result.is_a?(Hash) ? Array(result["value"]) : []
        end
      rescue Error
        []
      end
    end

    def token_account_pubkeys(address)
      token_accounts(address).filter_map { |a| a["pubkey"] }
    end

    def fetch_signatures(pubkey)
      result = rpc("getSignaturesForAddress", [ pubkey, { limit: SIGNATURES_PER_SOURCE } ])
      Array(result).map { |s| { signature: s["signature"], block_time: s["blockTime"] } }
    rescue Error
      []
    end

    def get_transaction(signature)
      rpc("getTransaction", [ signature, { encoding: "jsonParsed", maxSupportedTransactionVersion: 0 } ])
    end

    def parse_transaction(tx, wallet, block_time)
      return [] unless tx.is_a?(Hash)
      meta = tx["meta"] || {}
      return [] if meta["err"]

      timestamp = block_time.to_i
      signature = tx.dig("transaction", "signatures", 0)
      [ native_change(tx, meta, wallet, signature, timestamp), *token_changes(meta, wallet, signature, timestamp) ].compact
    end

    def native_change(tx, meta, wallet, signature, timestamp)
      keys = Array(tx.dig("transaction", "message", "accountKeys"))
      index = keys.index { |k| (k.is_a?(Hash) ? k["pubkey"] : k) == wallet }
      return nil unless index

      pre = Array(meta["preBalances"])[index]
      post = Array(meta["postBalances"])[index]
      return nil if pre.nil? || post.nil?

      delta = BigDecimal(post.to_i - pre.to_i) / LAMPORTS_PER_SOL
      return nil if delta.abs <= SOL_DUST

      { "hash" => signature, "onchain_amount" => delta.to_s, "timeStamp" => timestamp, "symbol" => "SOL" }
    end

    def token_changes(meta, wallet, signature, timestamp)
      pre = index_token_balances(meta["preTokenBalances"], wallet)
      post = index_token_balances(meta["postTokenBalances"], wallet)
      (pre.keys + post.keys).uniq.filter_map do |mint|
        delta = (post[mint] || 0.to_d) - (pre[mint] || 0.to_d)
        next if delta.zero?

        { "hash" => "#{signature}_#{mint}", "onchain_amount" => delta.to_s, "timeStamp" => timestamp, "mint" => mint }
      end
    end

    def index_token_balances(balances, wallet)
      Array(balances).each_with_object({}) do |b, acc|
        next unless b["owner"] == wallet

        mint = b["mint"].to_s
        ui = b.dig("uiTokenAmount", "uiAmountString") || b.dig("uiTokenAmount", "uiAmount")
        acc[mint] = BigDecimal(ui.to_s) if mint.present? && ui
      end
    rescue ArgumentError
      {}
    end

    def rpc(method, params)
      body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
      response = self.class.post(self.class.rpc_url, body: body)
      raise RateLimitError, "Solana RPC rate limited" if response.code == 429
      raise ApiError, "Solana RPC error (#{response.code})" unless response.code.between?(200, 299)

      payload = JSON.parse(response.body)
      raise ApiError, "Solana RPC error: #{payload.dig('error', 'message')}" if payload["error"]

      payload["result"]
    rescue JSON::ParserError => e
      raise ApiError, "Solana RPC returned invalid JSON: #{e.message}"
    end
end
