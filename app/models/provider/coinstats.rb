class Provider::Coinstats
  class AuthenticationError < StandardError; end
  class RateLimitError < StandardError; end

  BASE_URL = "https://openapiv1.coinstats.app"

  def initialize(api_key)
    @api_key = api_key
    @client = HTTP.headers(
      "X-API-KEY" => api_key,
      "User-Agent" => "Sure Finance CoinStats Client (https://github.com/we-promise/sure)"
    )
  end

  # Get the list of blockchains supported by CoinStats
  # https://coinstats.app/api-docs/openapi/get-blockchains
  def get_blockchains
    res = @client.get("#{BASE_URL}/wallet/blockchains")

    handle_response(res)
  end

  # Get cryptocurrency balances for any blockchain wallet
  # https://coinstats.app/api-docs/openapi/get-wallet-balance
  def get_wallet_balance(address, blockchain)
    res = @client.get("#{BASE_URL}/wallet/balance", params: { address: address, connectionId: blockchain })

    handle_response(res)
  end

  # Get transaction data for wallet addresses
  # https://coinstats.app/api-docs/openapi/get-wallet-transactions
  def get_wallet_transactions(address, blockchain)
    # Initiate syncing process to update transaction data
    # https://coinstats.app/api-docs/openapi/transactions-sync
    @client.patch("#{BASE_URL}/wallet/transactions", params: { address: address, connectionId: blockchain })

    sync_retry_current = 0
    sync_retry_max = 10
    sync_retry_delay = 5

    loop do
      sync_retry_current += 1

      # Get the syncing status of the provided wallet address with the blockchain network.
      # https://coinstats.app/api-docs/openapi/get-wallet-sync-status
      sync_res = @client.get("#{BASE_URL}/wallet/status", params: { address: address, connectionId: blockchain })
      sync_data = handle_response(sync_res)

      break if sync_data[:status] == "synced"

      if sync_retry_current >= sync_retry_max
        raise StandardError, "CoinStats wallet transactions sync timeout after #{sync_retry_current} attempts"
      end

      # Exponential backoff
      sleep sync_retry_delay * sync_retry_current
    end

    res = @client.get("#{BASE_URL}/wallet/transactions", params: { address: address, connectionId: blockchain })

    handle_response(res)
  end

  private

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
