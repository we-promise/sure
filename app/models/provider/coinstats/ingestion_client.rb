require "bigdecimal"
require "json"
require "time"

# One request per method, exact response values, and no side-effecting portfolio
# refresh. A separate shared readiness protocol must authorize asynchronous sync.
class Provider::Coinstats::IngestionClient
  PAGE_SIZE = 100
  MAX_BODY_BYTES = 20.megabytes
  NotReady = Class.new(Provider::Coinstats::Error)

  def initialize(api_key:)
    raise ArgumentError unless api_key.is_a?(String) && api_key.present?
    @api_key = api_key
  end

  def wallet_balances(address:, blockchain:)
    read("/wallet/balances", wallets: wallet_scope(address, blockchain))
  end

  def wallet_defi(address:, blockchain:)
    wallet_scope(address, blockchain)
    read("/wallet/defi", address: address, connectionId: blockchain)
  end

  def portfolio_coins(portfolio_id:, page: 1)
    read("/portfolio/coins", portfolioId: identifier(portfolio_id), page: page_number(page), limit: PAGE_SIZE)
  end

  # A single wallet is intentional: the old bulk flat transaction response did
  # not identify its wallet, so coin-only filtering could cross wallet scopes.
  # https://coinstats.app/api-docs/openapi/get-wallet-transactions/
  def wallet_transactions(address:, blockchain:, currency:, page: 1, from: nil, to:)
    read("/wallet/transactions", { wallets: wallet_scope(address, blockchain), currency: currency,
      page: page_number(page), limit: PAGE_SIZE, from: from, to: to }.compact)
  end

  def exchange_transactions(portfolio_id:, currency:, page: 1, from: nil, to:)
    read("/exchange/transactions", { portfolioId: identifier(portfolio_id), currency: currency,
      page: page_number(page), limit: PAGE_SIZE, from: from, to: to }.compact)
  end

  def portfolio_transactions(portfolio_id:, currency:, page: 1, from: nil, to:)
    read("/portfolio/transactions", { portfolioId: identifier(portfolio_id), currency: currency,
      page: page_number(page), limit: PAGE_SIZE, from: from, to: to }.compact)
  end

  def portfolio_status(portfolio_id:)
    read("/portfolio/status", portfolioId: identifier(portfolio_id))
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def read(path, query)
      # Local pacing matches the existing client floor. Shared API-key budget
      # coordination remains a cutover gate; a 429 never triggers a hidden loop.
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delay = @last_request_at && 0.5 - (now - @last_request_at)
      sleep(delay) if delay && delay.positive?
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Provider::Coinstats.get("#{Provider::Coinstats::BASE_URL}#{path}", query: query,
        headers: { "X-API-KEY" => @api_key, "Accept" => "application/json" }, follow_redirects: false)
      raise NotReady, "CoinStats history requires a completed upstream sync" if response.code.to_i == 409
      if response.code.to_i == 429
        delay = response.headers["Retry-After"] || response.headers["retry-after"]
        delay = Integer(delay, 10) rescue nil
        delay = nil unless delay && delay.between?(0, 86_400)
        raise Provider::Coinstats::RateLimitError.new("CoinStats request was rate limited", retry_after: delay)
      end
      raise Provider::Coinstats::Error, "CoinStats request failed" unless response.code.to_i == 200
      body = response.body
      raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES
      JSON.parse(body, decimal_class: BigDecimal)
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Provider::Coinstats::Error, "CoinStats response is invalid", cause: nil
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError
      raise Provider::Coinstats::Error, "CoinStats request unavailable", cause: nil
    end

    def page_number(value)
      raise ArgumentError unless value.is_a?(Integer) && value.between?(1, 100_000)
      value
    end

    def identifier(value)
      raise ArgumentError unless value.is_a?(String) && value.present? && value.bytesize <= 1024 && !value.match?(/[[:cntrl:]]/)
      value
    end

    def wallet_scope(address, blockchain)
      values = [ identifier(blockchain), identifier(address) ]
      raise ArgumentError if values.any? { |value| value.match?(/[,:]/) }
      values.join(":")
    end
end
