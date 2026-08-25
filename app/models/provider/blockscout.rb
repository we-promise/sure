# frozen_string_literal: true

# Keyless EVM data source backed by a public Blockscout instance.
#
# The default backend for every supported network: no API key, and its address
# summary answers "is this address worth tracking here?" in a single request,
# including for wallets that hold only tokens. The instance URL comes from the
# chain registry; self-hosters running their own indexer can override it with
# BLOCKSCOUT_<CHAIN>_URL.
class Provider::Blockscout
  include Provider::EvmExplorer
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # Flags the v2 address summary returns alongside the coin balance. They are
  # what lets a token-only wallet (zero native balance) be detected without
  # touching transfer history.
  ACTIVITY_FLAGS = %w[has_tokens has_token_transfers has_logs].freeze

  ERC20_TYPE = "ERC-20"

  DEFAULT_MAX_PAGES = 10
  MIN_REQUEST_INTERVAL = 0.2
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :chain, :base_url

  # True when any collection stopped on the page budget rather than on its last
  # page.
  attr_reader :truncated

  # Detection reads on the request thread and cannot afford the sync's patience,
  # so both the per-request timeout and the retry count are the caller's to set.
  def initialize(chain:, base_url:, max_pages: DEFAULT_MAX_PAGES, request_timeout: nil, max_retries: MAX_RETRIES)
    @chain = chain.to_s
    @base_url = ENV["BLOCKSCOUT_#{@chain.upcase}_URL"].presence || base_url
    @max_pages = max_pages
    @request_timeout = request_timeout
    @max_retries = max_retries
    @truncated = false
  end

  def has_activity?(address)
    summary = address_summary(address)
    return false unless summary.is_a?(Hash)

    summary["coin_balance"].to_s.to_d.positive? || ACTIVITY_FLAGS.any? { |flag| summary[flag] == true }
  end

  def native_balance(address)
    summary = address_summary(address)
    summary.is_a?(Hash) ? summary["coin_balance"].to_s : "0"
  end

  # This endpoint takes no `type` filter — passing one is a 422 — and it answers
  # with every token standard the address holds, so ERC-20 has to be selected
  # here. An ERC-721 or ERC-1155 row would otherwise be read as a fungible
  # balance, turning one NFT into "1 token".
  def token_balances(address)
    paginate("/api/v2/addresses/#{encode(address)}/token-balances").filter_map do |entry|
      token_data = entry["token"].to_h
      next unless token_data["type"].to_s == ERC20_TYPE

      contract = contract_of(token_data)
      next if contract.blank?

      {
        contract: contract,
        symbol: token_data["symbol"],
        name: token_data["name"],
        decimals: token_data["decimals"].to_i,
        raw_amount: entry["value"].to_s,
        # Blockscout's own market signals, used only to decide which tokens are
        # worth surfacing first when an address holds thousands of them, and
        # which are worth pre-ticking.
        market_cap: token_data["circulating_market_cap"].to_s.presence&.to_d,
        rate: token_data["exchange_rate"].to_s.presence&.to_d
      }
    end
  end

  def transfers(address)
    native_transfers(address) + token_transfers(address)
  end

  private
    def native_transfers(address)
      paginate("/api/v2/addresses/#{encode(address)}/transactions").filter_map do |transaction|
        raw_amount = signed_amount(transaction["value"], from: transaction.dig("from", "hash"), to: transaction.dig("to", "hash"), address: address)
        next if raw_amount.zero?

        {
          external_id: transaction["hash"],
          contract: nil,
          symbol: nil,
          decimals: 18,
          raw_amount: raw_amount,
          timestamp: parse_time(transaction["timestamp"])
        }
      end
    end

    def token_transfers(address)
      paginate("/api/v2/addresses/#{encode(address)}/token-transfers?type=ERC-20").filter_map do |transfer|
        token_data = transfer["token"].to_h
        total = transfer["total"].to_h
        contract = contract_of(token_data)
        next if contract.blank?

        raw_amount = signed_amount(total["value"], from: transfer.dig("from", "hash"), to: transfer.dig("to", "hash"), address: address)
        next if raw_amount.zero?

        {
          external_id: transfer_external_id(transfer["transaction_hash"], contract, transfer["log_index"]),
          contract: contract,
          symbol: token_data["symbol"],
          decimals: (total["decimals"] || token_data["decimals"]).to_i,
          raw_amount: raw_amount,
          timestamp: parse_time(transfer["timestamp"])
        }
      end
    end

    # A transaction can emit several transfers of the same token involving the
    # same address — swap routers and batch payouts do it routinely — so the
    # transaction hash and the contract are not unique together. The log index is
    # what makes an event unique within a transaction; the contract is only a
    # fallback for an instance that does not report one.
    def transfer_external_id(transaction_hash, contract, log_index)
      [ transaction_hash, log_index.nil? ? contract : log_index ].join("_")
    end

    # Blockscout renamed this field; accept both so an older self-hosted
    # instance keeps working.
    def contract_of(token)
      (token["address_hash"] || token["address"]).to_s.presence&.downcase
    end

    def signed_amount(value, from:, to:, address:)
      amount = value.to_s.presence&.to_i || 0
      target = address.to_s.downcase
      received = to.to_s.downcase == target
      sent = from.to_s.downcase == target

      return 0 if received == sent # neither, or a transfer to itself

      received ? amount : -amount
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def address_summary(address)
      @address_summary ||= {}
      @address_summary[address.to_s] ||= api_get("/api/v2/addresses/#{encode(address)}")
    end

    def encode(address)
      ERB::Util.url_encode(address.to_s)
    end

    def paginate(path)
      items = []
      next_params = nil

      @max_pages.times do
        url = path.dup
        url += (url.include?("?") ? "&" : "?") + URI.encode_www_form(next_params) if next_params.present?

        body = api_get(url)

        # Some v2 collections (token-balances) return a bare, complete array;
        # the paginated ones wrap items with cursor params.
        if body.is_a?(Array)
          items.concat(body)
          break
        end

        page = Array(body.is_a?(Hash) ? body["items"] : nil)
        items.concat(page)

        next_params = body.is_a?(Hash) ? body["next_page_params"] : nil
        break if next_params.blank? || page.empty?
      end

      # A cursor still in hand means there were more pages than the budget.
      @truncated ||= next_params.present?

      items
    end

    def api_get(path)
      attempts = 0

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.get("#{base_url}#{path}", **request_options)) }
      rescue RateLimitError => e
        raise if attempts > @max_retries

        Rails.logger.warn("Provider::Blockscout(#{chain}) - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
        retry
      end
    end

    def request_options(**options)
      return options if @request_timeout.nil?

      options.merge(timeout: @request_timeout)
    end

    def throttle_request
      @last_request_at ||= Time.at(0)
      remaining = MIN_REQUEST_INTERVAL - (Time.current - @last_request_at)
      sleep(remaining) if remaining.positive?
      @last_request_at = Time.current
    end

    def handle_response(response)
      raise RateLimitError, "Blockscout rate limit exceeded" if response.code == 429
      raise ApiError, "Blockscout API error: #{response.code}" unless response.code.between?(200, 299)

      response.parsed_response
    end
end
