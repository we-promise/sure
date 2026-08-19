# frozen_string_literal: true

class Provider::Wise
  include HTTParty
  extend SslConfigurable

  LIVE_BASE_URL = "https://api.wise.com"
  SANDBOX_BASE_URL = "https://api.sandbox.transferwise.tech"
  # Wise caps a single balance-statement request at 469 days; chunk at 468 to
  # stay safely within the limit while covering the full requested range.
  MAX_STATEMENT_DAYS = 468

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

  def get_balance_statement(profile_id, balance_id, interval_start:, interval_end:, currency: nil)
    get(
      "/v1/profiles/#{profile_id}/balance-statements/#{balance_id}/statement.json",
      query: {
        currency: currency,
        intervalStart: interval_start.to_time.utc.iso8601,
        intervalEnd: interval_end.to_time.utc.iso8601
      }
    )
  end

  def get_balance_statements(profile_id, balance_id, currency:, start_date:, end_date: Date.current)
    transactions = []
    window_start = start_date.to_date
    end_date = end_date.to_date

    while window_start <= end_date
      window_end = [ window_start + MAX_STATEMENT_DAYS - 1, end_date ].min
      response = with_rate_limit_retry do
        get_balance_statement(
          profile_id,
          balance_id,
          currency: currency,
          interval_start: window_start.beginning_of_day,
          interval_end: window_end.end_of_day
        )
      end
      transactions.concat(Array(response["transactions"] || response[:transactions]))
      window_start = window_end + 1.day
    end

    transactions
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

    private

      # Retries only the failed window so a rate-limited request does not
      # restart earlier windows in a multi-window statement fetch.
      def with_rate_limit_retry(max_retries: 3)
        retries = 0
        begin
          yield
        rescue WiseError => e
          raise unless e.error_type == :rate_limited && retries < max_retries
          retries += 1
          sleep(2 ** retries)
          retry
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
