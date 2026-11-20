# frozen_string_literal: true

# Keyless SPL token metadata.
#
# Solana RPC returns mints, not names, so without this every SPL token that is
# not hard-coded shows up as its mint and can never be priced. Jupiter's token
# search answers a batch of mints in one request and, crucially, says whether a
# token is *verified*.
#
# Only verified tokens are trusted. Anyone can mint a token calling itself USDC;
# naming an unverified one would hand it the real asset's price and value dust at
# thousands. An unverified or unknown mint keeps its placeholder instead.
class Provider::JupiterTokens
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_URL = "https://lite-api.jup.ag/tokens/v2/search"

  # Mints per request. The endpoint accepts a comma-separated batch; this bounds
  # both the URL length and the response size.
  BATCH_SIZE = 50
  # Metadata is effectively static, and a mint that resolves to nothing usually
  # stays that way, so misses are cached too rather than retried every sync.
  CACHE_TTL = 24.hours
  MISS = "unverified"

  default_options.merge!({ timeout: 15 }.merge(httparty_ssl_options))

  def self.url
    ENV["SOLANA_TOKEN_LIST_URL"].presence || DEFAULT_URL
  end

  # @param mints [Array<String>]
  # @return [Hash{String => Hash}] mint => { symbol:, name: }, verified mints only
  def metadata_for(mints)
    wanted = Array(mints).map(&:to_s).reject(&:blank?).uniq
    return {} if wanted.empty?

    resolved = {}
    missing = []

    wanted.each do |mint|
      cached = Rails.cache.read(cache_key(mint))
      if cached.nil?
        missing << mint
      elsif cached != MISS
        resolved[mint] = cached.symbolize_keys
      end
    end

    # The fetch returns what it found rather than reading its own writes back:
    # the cache is an optimisation here, not the source of truth (it may be a
    # null store).
    resolved.merge!(fetch_and_cache(missing)) if missing.any?
    resolved
  end

  private
    def fetch_and_cache(mints)
      found = {}

      mints.each_slice(BATCH_SIZE) do |batch|
        verified = verified_tokens(batch)

        batch.each do |mint|
          metadata = verified[mint]
          # Misses are cached too: a mint the list does not vouch for today is
          # unlikely to change by the next sync, and spam wallets hold many.
          Rails.cache.write(cache_key(mint), metadata || MISS, expires_in: CACHE_TTL)
          found[mint] = metadata.symbolize_keys if metadata
        end
      end

      found
    end

    def verified_tokens(mints)
      Array(get_json(mints)).each_with_object({}) do |token, resolved|
        mint = token["id"].to_s
        next if mint.blank?
        next unless token["isVerified"] == true

        symbol = token["symbol"].to_s.strip
        next if symbol.blank?

        resolved[mint] = { "symbol" => symbol, "name" => token["name"].to_s.presence || symbol }
      end
    end

    def cache_key(mint)
      "onchain:solana_mint:#{mint}"
    end

    def get_json(mints)
      translate_transport_errors do
        response = self.class.get(self.class.url, query: { query: mints.join(",") })

        raise RateLimitError, "Jupiter rate limit exceeded" if response.code == 429
        raise ApiError, "Jupiter token search error: #{response.code}" unless response.code.between?(200, 299)

        response.parsed_response
      end
    end
end
