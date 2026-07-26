# frozen_string_literal: true

class Provider::Wise
  include HTTParty
  extend SslConfigurable

  LIVE_BASE_URL = "https://api.wise.com"
  SANDBOX_BASE_URL = "https://api.sandbox.transferwise.tech"

  headers "User-Agent" => "Sure Finance Wise Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :token, :base_url

  def initialize(token, base_url: LIVE_BASE_URL)
    @token = token
    @base_url = base_url
  end

  def get_me
    get("/v1/me")
  end

  def get_profiles
    get("/v1/profiles")
  end

  def get_balances(profile_id)
    get("/v4/profiles/#{profile_id}/balances", query: { types: "STANDARD" })
  end

  def get_savings_balances(profile_id)
    get("/v4/profiles/#{profile_id}/balances", query: { types: "SAVINGS" })
  end

  def get_balance_statement(profile_id, balance_id, interval_start:, interval_end:)
    get(
      "/v1/profiles/#{profile_id}/balance-statements/#{balance_id}/statement.json",
      query: {
        intervalStart: interval_start.iso8601,
        intervalEnd: interval_end.iso8601
      }
    )
  end

  def get_transfers(profile_id, limit: 100, offset: 0)
    get(
      "/v1/transfers",
      query: { profile: profile_id, limit: limit, offset: offset }
    )
  end

  def get_transfer(transfer_id)
    get("/v1/transfers/#{transfer_id}")
  end

  def get_activities(profile_id, cursor: nil, size: 100)
    query = { size: size }
    query[:cursor] = cursor if cursor
    get("/v1/profiles/#{profile_id}/activities", query: query)
  end

  def get_borderless_accounts(profile_id)
    get("/v1/borderless-accounts", query: { profileId: profile_id })
  end

  private

    def get(path, query: {})
      response = self.class.get(
        "#{base_url}#{path}",
        headers: auth_headers,
        query: query.presence
      )
      handle_response(response)
    rescue WiseError
      raise
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise WiseError.new("Connection failed: #{e.message}", :request_failed)
    rescue => e
      raise WiseError.new("Unexpected error: #{e.message}", :request_failed)
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body)
      when 401
        raise WiseError.new("Invalid API token", :unauthorized)
      when 403
        raise WiseError.new("Access forbidden — check token permissions", :access_forbidden)
      when 404
        raise WiseError.new("Resource not found", :not_found)
      when 429
        raise WiseError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        raise WiseError.new("Unexpected response #{response.code}: #{response.body}", :fetch_failed)
      end
    end

    class WiseError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
