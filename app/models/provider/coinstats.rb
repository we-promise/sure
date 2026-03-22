# API client for CoinStats cryptocurrency data provider.
# Handles authentication and requests to the CoinStats OpenAPI.
class Provider::Coinstats < Provider
  include HTTParty
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Coinstats::Error
  Error = Class.new(Provider::Error)

  BASE_URL = "https://openapiv1.coinstats.app"

  headers "User-Agent" => "Sure Finance CoinStats Client (https://github.com/we-promise/sure)"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :api_key

  # @param api_key [String] CoinStats API key for authentication
  def initialize(api_key)
    @api_key = api_key
  end

  # Get the list of blockchains supported by CoinStats
  # https://coinstats.app/api-docs/openapi/get-blockchains
  def get_blockchains
    with_provider_response do
      res = self.class.get("#{BASE_URL}/wallet/blockchains", headers: auth_headers)
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /wallet/blockchains failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  # Returns blockchain options formatted for select dropdowns
  # @return [Array<Array>] Array of [label, value] pairs sorted alphabetically
  def blockchain_options
    response = get_blockchains

    unless response.success?
      Rails.logger.warn("CoinStats: failed to fetch blockchains: #{response.error&.message}")
      return []
    end

    raw_blockchains = response.data
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
  # @return [Provider::Response] Response with wallet balance data
  def get_wallet_balances(wallets)
    return with_provider_response { [] } if wallets.blank?

    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/wallet/balances",
        headers: auth_headers,
        query: { wallets: wallets }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /wallet/balances failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
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
  # @return [Provider::Response] Response with wallet transaction data
  def get_wallet_transactions(wallets)
    return with_provider_response { [] } if wallets.blank?

    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/wallet/transactions",
        headers: auth_headers,
        query: { wallets: wallets }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /wallet/transactions failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
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
        log_api_error(response, "Bad Request")
        raise Error, "CoinStats: Invalid request parameters"
      when 401
        log_api_error(response, "Unauthorized")
        raise Error, "CoinStats: Invalid or missing API key"
      when 403
        log_api_error(response, "Forbidden")
        raise Error, "CoinStats: Access denied"
      when 404
        log_api_error(response, "Not Found")
        raise Error, "CoinStats: Resource not found"
      when 409
        log_api_error(response, "Conflict")
        raise Error, "CoinStats: Resource conflict"
      when 429
        log_api_error(response, "Too Many Requests")
        raise Error, "CoinStats: Rate limit exceeded, try again later"
      when 500
        log_api_error(response, "Internal Server Error")
        raise Error, "CoinStats: Server error, try again later"
      when 503
        log_api_error(response, "Service Unavailable")
        raise Error, "CoinStats: Service temporarily unavailable"
      else
        log_api_error(response, "Unexpected Error")
        raise Error, "CoinStats: An unexpected error occurred"
      end
    end

    def log_api_error(response, error_type)
      Rails.logger.error "CoinStats API: #{response.code} #{error_type} - #{response.body}"
    end
end
