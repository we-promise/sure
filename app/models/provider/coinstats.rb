class Provider::Coinstats
  include HTTParty

  class AuthenticationError < StandardError; end
  class RateLimitError < StandardError; end

  BASE_URL = "https://openapiv1.coinstats.app"

  headers "User-Agent" => "Sure Finance CoinStats Client (https://github.com/we-promise/sure)"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  attr_reader :api_key

  def initialize(api_key)
    @api_key = api_key
  end

  # Get the list of blockchains supported by CoinStats
  # https://coinstats.app/api-docs/openapi/get-blockchains
  def get_blockchains
    res = self.class.get("#{BASE_URL}/wallet/blockchains", headers: auth_headers)

    handle_response(res)
  end

  # Returns blockchain options formatted for select dropdowns
  # @return [Array<Array>] Array of [label, value] pairs sorted alphabetically
  def blockchain_options
    raw_blockchains = get_blockchains

    items = if raw_blockchains.is_a?(Array)
      raw_blockchains
    elsif raw_blockchains.respond_to?(:dig) && raw_blockchains[:data].is_a?(Array)
      raw_blockchains[:data]
    else
      []
    end

    items.filter_map do |b|
      b = b.with_indifferent_access
      value = b[:connectionId] || b[:id] || b[:name]
      next unless value.present?

      label = b[:name].presence || value.to_s
      [ label, value ]
    end.uniq { |_label, value| value }.sort_by { |label, _| label.to_s.downcase }
  rescue StandardError => e
    Rails.logger.warn("CoinStats: failed to fetch blockchains: #{e.class} - #{e.message}")
    []
  end

  # Get cryptocurrency balances for any blockchain wallet
  # https://coinstats.app/api-docs/openapi/get-wallet-balance
  def get_wallet_balance(address, blockchain)
    res = self.class.get(
      "#{BASE_URL}/wallet/balance",
      headers: auth_headers,
      query: { address: address, connectionId: blockchain }
    )

    handle_response(res)
  end

  # Get transaction data for wallet addresses
  # https://coinstats.app/api-docs/openapi/get-wallet-transactions
  def get_wallet_transactions(address, blockchain)
    # Initiate syncing process to update transaction data
    # https://coinstats.app/api-docs/openapi/transactions-sync
    self.class.patch(
      "#{BASE_URL}/wallet/transactions",
      headers: auth_headers,
      query: { address: address, connectionId: blockchain }
    )

    sync_retry_current = 0
    sync_retry_max = 10
    sync_retry_delay = 5

    loop do
      sync_retry_current += 1

      # Get the syncing status of the provided wallet address with the blockchain network.
      # https://coinstats.app/api-docs/openapi/get-wallet-sync-status
      sync_res = self.class.get(
        "#{BASE_URL}/wallet/status",
        headers: auth_headers,
        query: { address: address, connectionId: blockchain }
      )
      sync_data = handle_response(sync_res)

      break if sync_data[:status] == "synced"

      if sync_retry_current >= sync_retry_max
        raise StandardError, "CoinStats wallet transactions sync timeout after #{sync_retry_current} attempts"
      end

      # Exponential backoff
      sleep sync_retry_delay * sync_retry_current
    end

    # Paginate through all transactions using max limit
    all_transactions = []
    page = 1
    limit = 100 # Maximum allowed by API

    loop do
      res = self.class.get(
        "#{BASE_URL}/wallet/transactions",
        headers: auth_headers,
        query: { address: address, connectionId: blockchain, page: page, limit: limit }
      )

      data = handle_response(res)
      transactions = data[:result] || data[:transactions] || data[:data] || []
      break if transactions.empty?

      all_transactions.concat(transactions)

      # Stop if we received fewer than the limit (last page)
      break if transactions.size < limit

      page += 1
    end

    all_transactions
  end

  private

    def auth_headers
      {
        "X-API-KEY" => api_key,
        "Accept" => "application/json"
      }
    end

    # The CoinStats API uses standard HTTP status codes to indicate the success or failure of requests.
    # https://coinstats.app/api-docs/errors
    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        raise StandardError, "CoinStats: #{response.code} Bad Request - Invalid parameters or request format #{response.body}"
      when 401
        raise AuthenticationError, "CoinStats: #{response.code} Unauthorized - Invalid or missing API key #{response.body}"
      when 403
        raise AuthenticationError, "CoinStats: #{response.code} Forbidden - #{response.body}"
      when 404
        raise StandardError, "CoinStats: #{response.code} Not Found - Resource not found #{response.body}"
      when 409
        raise StandardError, "CoinStats: #{response.code} Conflict - Resource conflict #{response.body}"
      when 429
        raise RateLimitError, "CoinStats: #{response.code} Too Many Requests - Rate limit exceeded #{response.body}"
      when 500
        raise StandardError, "CoinStats: #{response.code} Internal Server Error - Server error #{response.body}"
      when 503
        raise StandardError, "CoinStats: #{response.code} Service Unavailable - #{response.body}"
      else
        raise StandardError, "CoinStats: #{response.code} Unexpected Error - #{response.body}"
      end
    end
end
