# frozen_string_literal: true

class Provider::Coinspot
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class NonceError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://www.coinspot.com.au"
  READ_ONLY_PREFIX = "/api/v2/ro"

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:, nonce_generator: nil)
    @api_key = api_key # pipelock:ignore user-supplied CoinSpot credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied CoinSpot credential kept in memory for signed requests
    @nonce_generator = nonce_generator || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond).to_s }
  end

  def status
    read_only_post("/status")
  end

  def get_balances
    read_only_post("/my/balances")
  end

  def get_order_history(startdate: nil, enddate: nil)
    read_only_post("/my/orders/history", date_params(startdate: startdate, enddate: enddate))
  end

  def get_market_order_history(startdate: nil, enddate: nil)
    read_only_post("/my/orders/market/history", date_params(startdate: startdate, enddate: enddate))
  end

  def get_send_receive_history(startdate: nil, enddate: nil)
    read_only_post("/my/sendreceive", date_params(startdate: startdate, enddate: enddate))
  end

  def get_deposit_history(startdate: nil, enddate: nil)
    read_only_post("/my/deposits", date_params(startdate: startdate, enddate: enddate))
  end

  def get_withdrawal_history(startdate: nil, enddate: nil)
    read_only_post("/my/withdrawals", date_params(startdate: startdate, enddate: enddate))
  end

  private

    attr_reader :nonce_generator

    def date_params(startdate:, enddate:)
      {}.tap do |params|
        params["startdate"] = startdate.to_date.to_s if startdate.present?
        params["enddate"] = enddate.to_date.to_s if enddate.present?
      end
    end

    def read_only_post(path, params = {})
      request_params = { "nonce" => nonce_generator.call.to_s }.merge(stringify_params(params))
      body = JSON.generate(request_params)

      response = self.class.post(
        "#{READ_ONLY_PREFIX}#{path}",
        body: body,
        headers: {
          "Content-Type" => "application/json",
          "key" => api_key,
          "sign" => sign(body)
        }
      )

      handle_response(response)
    end

    def stringify_params(params)
      params.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value.to_s }
    end

    def sign(body)
      OpenSSL::HMAC.hexdigest("sha512", api_secret, body)
    end

    def handle_response(response)
      parsed = response.parsed_response

      unless response.code.between?(200, 299)
        raise ApiError, "CoinSpot API request failed: #{response.code}"
      end

      raise ApiError, "Malformed CoinSpot API response" unless parsed.is_a?(Hash)

      status = parsed["status"].to_s.downcase
      raise classified_error(parsed["message"].presence || "CoinSpot API request failed") if status == "error"

      parsed
    end

    def classified_error(message)
      case message
      when /invalid key|invalid signature|authentication|unauthori[sz]ed/i
        AuthenticationError.new(message)
      when /permission|read.only|read only/i
        PermissionError.new(message)
      when /nonce/i
        NonceError.new(message)
      when /rate|too many|limit/i
        RateLimitError.new(message)
      else
        ApiError.new(message)
      end
    end
end
