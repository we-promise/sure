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

  # Get cryptocurrency balances for multiple wallets in a single request
  # https://coinstats.app/api-docs/openapi/get-wallet-balances
  # @param wallets [String] Comma-separated list of wallet addresses in format "blockchain:address"
  #   Example: "ethereum:0x123abc,bitcoin:bc1qxyz"
  # @return [Array<Hash>] Array of wallet balance data with blockchain, address, connectionId, and balances
  def get_wallet_balances(wallets)
    return [] if wallets.blank?

    res = self.class.get(
      "#{BASE_URL}/wallet/balances",
      headers: auth_headers,
      query: { wallets: wallets }
    )

    handle_response(res)
  end

  # Extract balance data for a specific wallet from bulk response
  # @param bulk_data [Array<Hash>] Response from get_wallet_balances
  # @param address [String] Wallet address to find
  # @param blockchain [String] Blockchain/connectionId to find
  # @return [Array<Hash>] Token balances for the wallet, or empty array if not found
  def extract_wallet_balance(bulk_data, address, blockchain)
    return [] unless bulk_data.is_a?(Array)

    wallet_data = bulk_data.find do |entry|
      entry = entry.with_indifferent_access
      entry[:address]&.downcase == address&.downcase &&
        (entry[:connectionId]&.downcase == blockchain&.downcase ||
         entry[:blockchain]&.downcase == blockchain&.downcase)
    end

    return [] unless wallet_data

    wallet_data = wallet_data.with_indifferent_access
    wallet_data[:balances] || []
  end

  # Get transaction data for multiple wallet addresses in a single request
  # https://coinstats.app/api-docs/openapi/get-wallet-transactions
  # @param wallets [String] Comma-separated list of wallet addresses in format "blockchain:address"
  #   Example: "ethereum:0x123abc,bitcoin:bc1qxyz"
  # @return [Array<Hash>] Array of wallet transaction data with blockchain, address, and transactions
  def get_wallet_transactions(wallets)
    return [] if wallets.blank?

    res = self.class.get(
      "#{BASE_URL}/wallet/transactions",
      headers: auth_headers,
      query: { wallets: wallets }
    )

    handle_response(res)
  end

  # Extract transaction data for a specific wallet from bulk response
  # The transactions API returns {result: Array<transactions>, meta: {...}}
  # All transactions in the response belong to the requested wallets
  # @param bulk_data [Hash, Array] Response from get_wallet_transactions
  # @param address [String] Wallet address to filter by (currently unused as API returns flat list)
  # @param blockchain [String] Blockchain/connectionId to filter by (currently unused)
  # @return [Array<Hash>] Transactions for the wallet, or empty array if not found
  def extract_wallet_transactions(bulk_data, address, blockchain)
    # Handle Hash response with :result key (current API format)
    if bulk_data.is_a?(Hash)
      bulk_data = bulk_data.with_indifferent_access
      return bulk_data[:result] || []
    end

    # Handle legacy Array format (per-wallet structure)
    return [] unless bulk_data.is_a?(Array)

    wallet_data = bulk_data.find do |entry|
      entry = entry.with_indifferent_access
      entry[:address]&.downcase == address&.downcase &&
        (entry[:connectionId]&.downcase == blockchain&.downcase ||
         entry[:blockchain]&.downcase == blockchain&.downcase)
    end

    return [] unless wallet_data

    wallet_data = wallet_data.with_indifferent_access
    wallet_data[:transactions] || []
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
