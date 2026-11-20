# frozen_string_literal: true

# Keyed EVM data source backed by Etherscan's v2 API.
#
# A history-only backend: optional, and only for the chain the registry gives an
# Etherscan chain id. A key buys a higher rate limit on the paginated half of the
# work and nothing else, so balances and activity detection stay on the keyless
# indexer and this class refuses to answer them.
class Provider::Etherscan
  include Provider::EvmExplorer
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://api.etherscan.io/v2"
  PAGE_SIZE = 1000
  DEFAULT_MAX_PAGES = 10
  # The free tier allows 5 requests/second; stay well inside it.
  MIN_REQUEST_INTERVAL = 0.4
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :chain_id

  # True when a walk stopped on the page budget rather than on its last page.
  attr_reader :truncated

  def initialize(api_key:, chain_id:, max_pages: DEFAULT_MAX_PAGES)
    @api_key = api_key.to_s.strip
    @chain_id = chain_id.to_s
    @max_pages = max_pages
    @truncated = false
    raise AuthenticationError, "Etherscan API key is required" if @api_key.blank?
  end

  # Not implemented on purpose. Etherscan's one-request answer is the native
  # balance, which reports "nothing here" for a wallet holding only ERC-20
  # tokens, and the alternative is reading transfer history. Detection therefore
  # stays on the keyless indexer, whose address summary answers correctly in one
  # request.
  def has_activity?(_address)
    raise NotImplementedError, "Etherscan cannot answer activity in one request; use the keyless backend"
  end

  # Not implemented on purpose. Etherscan has no free endpoint that enumerates an
  # address's tokens, and summing transfer history cannot see a rebasing token's
  # current balance — nor anything older than the history cap. Balances always
  # come from the keyless indexer, so both backends agree on what is held.
  def token_balances(_address)
    raise NotImplementedError, "Etherscan cannot enumerate token balances; use the keyless backend"
  end

  def transfers(address)
    @transfers ||= {}
    @transfers[address.to_s] ||= native_transfers(address) + token_transfers(address)
  end

  private
    def native_transfers(address)
      paged_get(action: "txlist", address: address).filter_map do |transaction|
        raw_amount = signed_amount(transaction["value"], from: transaction["from"], to: transaction["to"], address: address)
        next if raw_amount.zero?

        {
          external_id: transaction["hash"],
          contract: nil,
          symbol: nil,
          name: nil,
          decimals: 18,
          raw_amount: raw_amount,
          timestamp: parse_time(transaction["timeStamp"])
        }
      end
    end

    def token_transfers(address)
      paged_get(action: "tokentx", address: address).filter_map do |transfer|
        contract = transfer["contractAddress"].to_s.presence&.downcase
        next if contract.blank?

        raw_amount = signed_amount(transfer["value"], from: transfer["from"], to: transfer["to"], address: address)
        next if raw_amount.zero?

        {
          external_id: transfer_external_id(transfer["hash"], contract, transfer["logIndex"]),
          contract: contract,
          symbol: transfer["tokenSymbol"],
          name: transfer["tokenName"],
          decimals: transfer["tokenDecimal"].to_i,
          raw_amount: raw_amount,
          timestamp: parse_time(transfer["timeStamp"])
        }
      end
    end

    # See Provider::Blockscout#transfer_external_id: the log index is what makes
    # one of several same-token transfers in a transaction distinct.
    def transfer_external_id(transaction_hash, contract, log_index)
      [ transaction_hash, log_index.presence || contract ].join("_")
    end

    def signed_amount(value, from:, to:, address:)
      amount = value.to_s.presence&.to_i || 0
      target = address.to_s.downcase
      received = to.to_s.downcase == target
      sent = from.to_s.downcase == target

      return 0 if received == sent

      received ? amount : -amount
    end

    def parse_time(unix_timestamp)
      return nil if unix_timestamp.blank?

      Time.zone.at(unix_timestamp.to_i)
    end

    def paged_get(action:, address:)
      results = []

      1.upto(@max_pages) do |page|
        batch = api_get(
          action: action,
          address: address,
          startblock: 0,
          endblock: 999_999_999,
          page: page,
          offset: PAGE_SIZE,
          sort: "asc"
        )
        batch = [] unless batch.is_a?(Array)
        results.concat(batch)
        break if batch.size < PAGE_SIZE

        @truncated ||= page == @max_pages
      end

      results
    end

    def api_get(params)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors do
          response = self.class.get("/api", query: {
            apikey: api_key,
            chainid: chain_id,
            module: "account"
          }.merge(params))
          handle_response(response)
        end
      rescue RateLimitError => e
        raise if attempts > MAX_RETRIES

        Rails.logger.warn("Provider::Etherscan - rate limited (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}")
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
      raise RateLimitError, "Etherscan rate limit exceeded" if response.code == 429
      raise ApiError, "Etherscan API error: #{response.code}" unless response.code.between?(200, 299)

      parsed = response.parsed_response
      raise ApiError, "Unexpected Etherscan response" unless parsed.is_a?(Hash)

      return parsed["result"] if parsed["status"].to_s == "1"
      return [] if parsed["message"].to_s.match?(/No transactions found/i)

      raise_for(parsed["result"].presence || parsed["message"].presence || "Etherscan API error")
    end

    def raise_for(message)
      case message.to_s
      when /invalid api key|missing.*chainid|apikey/i
        raise AuthenticationError, message
      when /rate limit|max rate|daily limit/i
        raise RateLimitError, message
      else
        raise ApiError, message
      end
    end
end
