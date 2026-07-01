# frozen_string_literal: true

# Keyless EVM data provider backed by public Blockscout instances.
#
# Drop-in alternative to Provider::Etherscan: it exposes the same interface
# (#get_native_balance, #get_normal_transactions, #get_erc20_transfers) and
# returns Etherscan-shaped hashes, so the importer can use either provider
# without change. Unlike Etherscan it requires no API key and supports several
# EVM chains via per-chain Blockscout base URLs.
class Provider::Blockscout
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class UnsupportedChainError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # Public Blockscout instances per chain (all free, no API key). Each is
  # overridable via ENV (BLOCKSCOUT_<CHAIN>_URL) for self-hosters with their
  # own indexer.
  DEFAULT_BASE_URLS = {
    "ethereum" => "https://eth.blockscout.com",
    "polygon"  => "https://polygon.blockscout.com",
    "arbitrum" => "https://arbitrum.blockscout.com",
    "optimism" => "https://optimism.blockscout.com",
    "base"     => "https://base.blockscout.com",
    "gnosis"   => "https://gnosis.blockscout.com"
  }.freeze

  SUPPORTED_CHAINS = DEFAULT_BASE_URLS.keys.freeze

  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/
  MIN_REQUEST_INTERVAL = 0.2
  DEFAULT_MAX_RETRIES = 3
  DEFAULT_RETRY_BASE_DELAY = 0.5
  MAX_PAGES = 20

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :chain

  def initialize(chain: "ethereum", max_retries: DEFAULT_MAX_RETRIES, retry_base_delay: DEFAULT_RETRY_BASE_DELAY)
    @chain = chain.to_s.strip.downcase
    raise UnsupportedChainError, "Unsupported EVM chain: #{@chain}" unless SUPPORTED_CHAINS.include?(@chain)

    @max_retries = max_retries
    @retry_base_delay = retry_base_delay
  end

  def self.supported_chain?(chain)
    SUPPORTED_CHAINS.include?(chain.to_s.strip.downcase)
  end

  def valid_address?(address)
    address.to_s.match?(ADDRESS_PATTERN)
  end

  # Whether this address has any balance or token activity on this chain.
  # Used by auto-detect to find which EVM chain(s) a 0x address is active on.
  def has_activity?(address)
    return false unless valid_address?(address)

    get_native_balance(address).to_d.positive? || get_erc20_transfers(address).any?
  rescue Error
    false
  end

  # @return [String] native coin balance in wei (matches Etherscan's "balance")
  def get_native_balance(address)
    validate_address!(address)
    data = api_get("/api/v2/addresses/#{ERB::Util.url_encode(address)}")
    data.is_a?(Hash) ? data["coin_balance"].to_s : "0"
  end

  # @return [Array<Hash>] native transactions in Etherscan ("txlist") shape
  def get_normal_transactions(address, **)
    validate_address!(address)
    paginate("/api/v2/addresses/#{ERB::Util.url_encode(address)}/transactions").map do |tx|
      {
        "hash"      => tx["hash"],
        "from"      => tx.dig("from", "hash"),
        "to"        => tx.dig("to", "hash"),
        "value"     => tx["value"].to_s,
        "timeStamp" => to_unix(tx["timestamp"])
      }
    end
  end

  # @return [Array<Hash>] ERC-20 transfers in Etherscan ("tokentx") shape
  def get_erc20_transfers(address, **)
    validate_address!(address)
    path = "/api/v2/addresses/#{ERB::Util.url_encode(address)}/token-transfers?type=ERC-20"
    paginate(path).filter_map do |t|
      token = t["token"] || {}
      contract = (token["address_hash"] || token["address"]).to_s
      next if contract.blank?

      total = t["total"] || {}
      {
        "hash"            => t["transaction_hash"],
        "from"            => t.dig("from", "hash"),
        "to"              => t.dig("to", "hash"),
        "contractAddress" => contract,
        "tokenSymbol"     => token["symbol"],
        "tokenName"       => token["name"],
        "tokenDecimal"    => (total["decimals"] || token["decimals"]).to_s,
        "value"           => total["value"].to_s,
        "timeStamp"       => to_unix(t["timestamp"])
      }
    end
  end

  private
    def base_url
      ENV["BLOCKSCOUT_#{chain.upcase}_URL"].presence || DEFAULT_BASE_URLS.fetch(chain)
    end

    def validate_address!(address)
      raise InvalidAddressError, "Invalid EVM address" unless valid_address?(address)
    end

    def to_unix(timestamp)
      Time.parse(timestamp.to_s).to_i.to_s
    rescue ArgumentError, TypeError
      ""
    end

    # Walks Blockscout v2 cursor pagination, bounded by MAX_PAGES.
    def paginate(path)
      items = []
      next_params = nil

      MAX_PAGES.times do
        url = path.dup
        url += (path.include?("?") ? "&" : "?") + URI.encode_www_form(next_params) if next_params.present?

        body = api_get(url)
        page = Array(body.is_a?(Hash) ? body["items"] : nil)
        items.concat(page)

        next_params = body.is_a?(Hash) ? body["next_page_params"] : nil
        break if next_params.blank? || page.empty?
      end

      items
    end

    def api_get(path)
      attempts = 0
      begin
        attempts += 1
        throttle_request
        response = self.class.get("#{base_url}#{path}")
        handle_response(response)
      rescue RateLimitError => e
        raise if attempts > @max_retries
        delay = @retry_base_delay * (2**(attempts - 1))
        Rails.logger.warn "Provider::Blockscout(#{chain}) - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}; sleeping #{delay}s"
        sleep(delay)
        retry
      end
    end

    def throttle_request
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = MIN_REQUEST_INTERVAL - elapsed
      sleep(sleep_time) if sleep_time.positive?
      @last_request_time = Time.current
    end

    def handle_response(response)
      raise RateLimitError, "Blockscout rate limit exceeded" if response.code == 429
      raise ApiError, "Blockscout API error: #{response.code}" unless response.code.between?(200, 299)

      response.parsed_response
    end
end
