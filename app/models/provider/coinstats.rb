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

  # Get the list of exchange connections supported by CoinStats
  # https://coinstats.app/api-docs/openapi/get-exchanges
  def get_exchanges
    with_provider_response do
      res = self.class.get("#{BASE_URL}/exchange/support", headers: auth_headers)
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /exchange/support failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  def exchange_options
    response = get_exchanges

    unless response.success?
      Rails.logger.warn("CoinStats: failed to fetch exchanges: #{response.error&.message}")
      return []
    end

    Array(response.data).filter_map do |exchange|
      exchange = exchange.with_indifferent_access
      connection_id = exchange[:connectionId]
      next unless connection_id.present?

      {
        connection_id: connection_id.to_s,
        name: exchange[:name].presence || connection_id.to_s.titleize,
        icon: exchange[:icon],
        connection_fields: Array(exchange[:connectionFields]).map do |field|
          field = field.with_indifferent_access
          {
            key: field[:key].to_s,
            name: field[:name].presence || field[:key].to_s.humanize
          }
        end
      }
    end.sort_by { |exchange| exchange[:name].to_s.downcase }
  rescue StandardError => e
    Rails.logger.warn("CoinStats: failed to fetch exchanges: #{e.class} - #{e.message}")
    []
  end

  # Connect an exchange portfolio and return its portfolio id
  # https://coinstats.app/api-docs/openapi/connect-portfolio-exchange
  def connect_portfolio_exchange(connection_id:, connection_fields:, name: nil)
    with_provider_response do
      res = self.class.post(
        "#{BASE_URL}/portfolio/exchange",
        headers: auth_headers.merge("Content-Type" => "application/json"),
        body: {
          connectionId: connection_id,
          connectionFields: connection_fields,
          name: name
        }.compact.to_json
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: POST /portfolio/exchange failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  # Get all holdings for a CoinStats portfolio.
  # https://coinstats.app/api-docs/openapi/get-portfolio-coins
  def get_portfolio_coins(portfolio_id:, page: 1, limit: 100)
    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/portfolio/coins",
        headers: auth_headers,
        query: {
          portfolioId: portfolio_id,
          page: page,
          limit: limit
        }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /portfolio/coins failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  def list_portfolio_coins(portfolio_id:, limit: 100)
    page = 1
    results = []

    loop do
      response = get_portfolio_coins(portfolio_id: portfolio_id, page: page, limit: limit)
      raise response.error unless response.success?

      payload = response.data.with_indifferent_access
      page_results = Array(payload[:result])
      results.concat(page_results)

      break if page_results.size < limit

      page += 1
    end

    results
  end

  # Get all transactions for a CoinStats portfolio.
  # https://coinstats.app/api-docs/openapi/get-portfolio-transactions
  def get_portfolio_transactions(portfolio_id:, currency: "USD", page: 1, limit: 100, from: nil, to: nil, coin_id: nil)
    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/portfolio/transactions",
        headers: auth_headers,
        query: {
          portfolioId: portfolio_id,
          currency: currency,
          page: page,
          limit: limit,
          from: from,
          to: to,
          coinId: coin_id
        }.compact
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /portfolio/transactions failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  def list_portfolio_transactions(portfolio_id:, currency: "USD", limit: 100, from: nil, to: nil)
    page = 1
    results = []

    loop do
      response = get_portfolio_transactions(
        portfolio_id: portfolio_id,
        currency: currency,
        page: page,
        limit: limit,
        from: from,
        to: to
      )
      raise response.error unless response.success?

      payload = response.data.with_indifferent_access
      page_results = Array(payload[:data] || payload[:result])
      results.concat(page_results)

      break if page_results.size < limit

      page += 1
    end

    results
  end

  # Get transaction data for a specific exchange portfolio.
  # https://coinstats.app/api-docs/openapi/get-exchange-transactions
  def get_exchange_transactions(portfolio_id:, currency: "USD", page: 1, limit: 100, from: nil, to: nil)
    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/exchange/transactions",
        headers: auth_headers,
        query: {
          portfolioId: portfolio_id,
          currency: currency,
          page: page,
          limit: limit,
          from: from,
          to: to
        }.compact
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /exchange/transactions failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  def list_exchange_transactions(portfolio_id:, currency: "USD", limit: 100, from: nil, to: nil)
    page = 1
    results = []

    loop do
      response = get_exchange_transactions(
        portfolio_id: portfolio_id,
        currency: currency,
        page: page,
        limit: limit,
        from: from,
        to: to
      )
      raise response.error unless response.success?

      payload = response.data.with_indifferent_access
      page_results = Array(payload[:result] || payload[:data])
      results.concat(page_results)

      break if page_results.size < limit

      page += 1
    end

    results
  end

  # Trigger a fresh CoinStats sync for the portfolio.
  # https://coinstats.app/api-docs/openapi/sync-portfolio
  def sync_portfolio(portfolio_id:)
    with_provider_response do
      res = self.class.patch(
        "#{BASE_URL}/portfolio/sync",
        headers: auth_headers,
        query: { portfolioId: portfolio_id }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: PATCH /portfolio/sync failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  # Trigger a fresh CoinStats exchange sync for the portfolio.
  # https://coinstats.app/api-docs/openapi/exchange-sync-status
  def sync_exchange(portfolio_id:)
    with_provider_response do
      res = self.class.patch(
        "#{BASE_URL}/exchange/sync",
        headers: auth_headers,
        query: { portfolioId: portfolio_id }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: PATCH /exchange/sync failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  # Get current sync status for the portfolio.
  # https://coinstats.app/api-docs/openapi/get-portfolio-sync-status
  def get_portfolio_sync_status(portfolio_id:)
    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/portfolio/status",
        headers: auth_headers,
        query: { portfolioId: portfolio_id }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /portfolio/status failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
  end

  # Get DeFi positions (staking, LP, yield farming) for a wallet address.
  # https://coinstats.app/api-docs/openapi/get-wallet-defi
  # @param address [String] Wallet address
  # @param connection_id [String] Blockchain/connectionId identifier
  # @return [Provider::Response] Response with DeFi position data
  def get_wallet_defi(address:, connection_id:)
    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/wallet/defi",
        headers: auth_headers,
        query: { address: address, connectionId: connection_id }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "CoinStats API: GET /wallet/defi failed: #{e.class}: #{e.message}"
    raise Error, "CoinStats API request failed: #{e.message}"
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
        raise_api_error(response, fallback: "CoinStats: Invalid request parameters")
      when 401
        log_api_error(response, "Unauthorized")
        raise_api_error(response, fallback: "CoinStats: Invalid or missing API key")
      when 403
        log_api_error(response, "Forbidden")
        raise_api_error(response, fallback: "CoinStats: Access denied")
      when 404
        log_api_error(response, "Not Found")
        raise_api_error(response, fallback: "CoinStats: Resource not found")
      when 409
        log_api_error(response, "Conflict")
        raise_api_error(response, fallback: "CoinStats: Resource conflict")
      when 429
        log_api_error(response, "Too Many Requests")
        raise_api_error(response, fallback: "CoinStats: Rate limit exceeded, try again later")
      when 500
        log_api_error(response, "Internal Server Error")
        raise_api_error(response, fallback: "CoinStats: Server error, try again later")
      when 503
        log_api_error(response, "Service Unavailable")
        raise_api_error(response, fallback: "CoinStats: Service temporarily unavailable")
      else
        log_api_error(response, "Unexpected Error")
        raise_api_error(response, fallback: "CoinStats: An unexpected error occurred")
      end
    end

    def log_api_error(response, error_type)
      Rails.logger.error "CoinStats API: #{response.code} #{error_type} - #{response.body}"
    end

    def raise_api_error(response, fallback:)
      error_payload = parse_error_payload(response.body)
      message = error_payload[:message].presence || fallback
      request_id = error_payload[:request_id].presence

      message = "#{message} (requestId: #{request_id})" if request_id.present?

      raise Error.new(message, details: error_payload.compact.presence)
    end

    def parse_error_payload(body)
      payload = JSON.parse(body.presence || "{}", symbolize_names: true)

      {
        status_code: payload[:statusCode] || payload[:status_code],
        message: payload[:message],
        request_id: payload[:requestId] || payload[:request_id],
        path: payload[:path]
      }
    rescue JSON::ParserError
      {}
    end
end
