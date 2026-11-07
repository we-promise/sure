require "cgi"

# Client for the GoCardless Bank Account Data API (formerly Nordigen).
#
# Covers the UK and EU/EEA via PSD2 open banking, which makes it the counterpart to
# Enable Banking for UK institutions: Enable Banking is EU/EEA only, so UK users
# (NatWest, Barclays, Lloyds, Monzo, Starling and so on) need this one.
#
# Two things about this API differ from every other provider here and drive the design
# below:
#
# 1. Trailing slashes are load-bearing. `/api/v2/institutions/` works, and
#    `/api/v2/institutions` redirects, dropping the Authorization header on the way and
#    surfacing as a confusing 401. Every path in this class ends in a slash on purpose.
#
# 2. Account endpoints are rate limited to a handful of calls per account per day
#    (commonly 4, and the account is the unit, not the connection). Blowing through it
#    returns 429 for the rest of the day. So a 429 is a normal operating condition to be
#    reported and skipped, not a sync failure, and callers should treat
#    GocardlessError#rate_limited? as "come back tomorrow" rather than an error state.
class Provider::Gocardless
  include HTTParty
  extend SslConfigurable

  BASE_URL = "https://bankaccountdata.gocardless.com".freeze

  # GoCardless caps consent at 90 days for most institutions, and each institution
  # advertises its own max via `max_access_valid_for_days`. Used as the ceiling when an
  # institution does not specify one.
  DEFAULT_ACCESS_VALID_FOR_DAYS = 90

  # Institutions advertise `transaction_total_days` (often 90, sometimes 730). Used when
  # an institution does not declare its own history window.
  DEFAULT_MAX_HISTORICAL_DAYS = 90

  ACCESS_SCOPE = %w[balances details transactions].freeze

  headers "User-Agent" => "Sure Finance GoCardless Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :secret_id

  def initialize(secret_id:, secret_key:)
    @secret_id = secret_id
    @secret_key = secret_key
  end

  # List institutions (banks) available in a country.
  # @param country [String] ISO 3166-1 alpha-2 code, e.g. "GB", "IE", "DE"
  # @return [Array<Hash>] institutions with :id, :name, :bic, :logo,
  #   :transaction_total_days, :max_access_valid_for_days
  def get_institutions(country:)
    get("/api/v2/institutions/", query: { country: country.to_s.downcase })
  end

  # Fetch a single institution, used to read its consent and history limits.
  # @param institution_id [String] e.g. "NATWEST_NWBKGB2L"
  # @return [Hash]
  def get_institution(institution_id:)
    get("/api/v2/institutions/#{CGI.escape(institution_id.to_s)}/")
  end

  # Create an end user agreement, which fixes how much history and how long an access
  # window this connection gets. Optional in the API, but creating one explicitly is the
  # only way to ask for more than the institution's default history.
  # @param institution_id [String]
  # @param max_historical_days [Integer]
  # @param access_valid_for_days [Integer]
  # @return [Hash] with :id
  def create_agreement(institution_id:, max_historical_days: DEFAULT_MAX_HISTORICAL_DAYS,
                       access_valid_for_days: DEFAULT_ACCESS_VALID_FOR_DAYS)
    post("/api/v2/agreements/enduser/", body: {
      institution_id: institution_id,
      max_historical_days: max_historical_days.to_i,
      access_valid_for_days: access_valid_for_days.to_i,
      access_scope: ACCESS_SCOPE
    })
  end

  # Start the authorisation flow. The returned :link is where the user must be sent to
  # authenticate with their bank; they come back to `redirect` afterwards.
  # @param institution_id [String]
  # @param redirect [String] absolute callback URL, must be registered with GoCardless
  # @param reference [String] our own opaque id, echoed back so we can match the
  #   callback to the item that started it
  # @param agreement [String, nil] agreement id from #create_agreement
  # @param user_language [String, nil] two-letter code, e.g. "EN"
  # @return [Hash] with :id, :link, :status
  def create_requisition(institution_id:, redirect:, reference: nil, agreement: nil, user_language: nil)
    body = {
      institution_id: institution_id,
      redirect: redirect,
      reference: reference,
      agreement: agreement,
      user_language: user_language
    }.compact

    post("/api/v2/requisitions/", body: body)
  end

  # Read a requisition, including the account ids once the user has consented.
  # Status codes: CR created, GC giving consent, UA undergoing authentication,
  # RJ rejected, SA selecting accounts, GA granting access, LN linked, EX expired.
  # Accounts are only populated once status is LN.
  # @param requisition_id [String]
  # @return [Hash] with :id, :status, :accounts
  def get_requisition(requisition_id:)
    get("/api/v2/requisitions/#{CGI.escape(requisition_id.to_s)}/")
  end

  # Revoke a connection. Called when the user unlinks, so consent does not outlive the
  # item in Sure.
  # @param requisition_id [String]
  def delete_requisition(requisition_id:)
    delete("/api/v2/requisitions/#{CGI.escape(requisition_id.to_s)}/")
  end

  # Account metadata: institution id, IBAN, owner, status. Not rate limited as
  # aggressively as the data endpoints below.
  # @param account_id [String]
  # @return [Hash]
  def get_account(account_id:)
    get("/api/v2/accounts/#{CGI.escape(account_id.to_s)}/")
  end

  # @param account_id [String]
  # @return [Hash] with :account holding name, currency, iban, product
  # @raise [GocardlessError] :rate_limited when the daily quota is spent
  def get_account_details(account_id:)
    get("/api/v2/accounts/#{CGI.escape(account_id.to_s)}/details/")
  end

  # @param account_id [String]
  # @return [Hash] with :balances, each having :balanceAmount and :balanceType
  # @raise [GocardlessError] :rate_limited when the daily quota is spent
  def get_account_balances(account_id:)
    get("/api/v2/accounts/#{CGI.escape(account_id.to_s)}/balances/")
  end

  # @param account_id [String]
  # @param date_from [Date, nil]
  # @param date_to [Date, nil]
  # @return [Hash] with :transactions => { :booked => [], :pending => [] }
  # @raise [GocardlessError] :rate_limited when the daily quota is spent
  def get_account_transactions(account_id:, date_from: nil, date_to: nil)
    query = {}
    query[:date_from] = date_from.to_date.iso8601 if date_from
    query[:date_to] = date_to.to_date.iso8601 if date_to

    get("/api/v2/accounts/#{CGI.escape(account_id.to_s)}/transactions/", query: query.presence)
  end

  private

    attr_reader :secret_key

    def get(path, query: nil)
      request(:get, path, query: query)
    end

    def post(path, body: nil)
      request(:post, path, body: body)
    end

    def delete(path)
      request(:delete, path)
    end

    # Single funnel for every call so auth, retry-on-expiry and error mapping live in one
    # place. A 401 is retried exactly once with a freshly minted token, because a cached
    # access token can expire mid-sync; the retry flag stops that becoming a loop when
    # the credentials themselves are simply wrong.
    def request(verb, path, query: nil, body: nil, retried: false)
      options = { headers: auth_headers }
      options[:query] = query if query.present?
      options[:body] = body.to_json if body.present?

      response = self.class.public_send(verb, "#{BASE_URL}#{path}", options)

      if response.code == 401 && !retried
        clear_cached_token
        return request(verb, path, query: query, body: body, retried: true)
      end

      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise GocardlessError.new("Exception during #{verb.to_s.upcase} request: #{e.message}", :request_failed)
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Accept" => "application/json",
        "Content-Type" => "application/json"
      }
    end

    # Access tokens last 24h. Minting one is itself a rate-limited network call, so the
    # token is cached across instances, keyed by a digest of the credentials (never the
    # credentials themselves) so that rotating them invalidates the cache for free.
    def access_token
      Rails.cache.fetch(token_cache_key, expires_in: cached_token_ttl) do
        mint_access_token
      end
    end

    def mint_access_token
      response = self.class.post(
        "#{BASE_URL}/api/v2/token/new/",
        headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
        body: { secret_id: secret_id, secret_key: secret_key }.to_json
      )

      data = handle_response(response)
      token = data[:access]

      raise GocardlessError.new("No access token in GoCardless token response", :unauthorized) if token.blank?

      # Expire our cache a minute before GoCardless does, so a token cannot go stale
      # between the cache read and the API call using it.
      @cached_token_ttl = [ data[:access_expires].to_i - 60, 60 ].max.seconds
      token
    end

    def cached_token_ttl
      @cached_token_ttl || 23.hours
    end

    def token_cache_key
      "gocardless/access_token/#{Digest::SHA256.hexdigest([ secret_id, secret_key ].to_json)}"
    end

    def clear_cached_token
      Rails.cache.delete(token_cache_key)
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        data = parse_error_response_body(response)
        raise GocardlessError.new("Bad request to GoCardless API: #{response.body}", :bad_request, response_data: data)
      when 401
        raise AuthenticationError.new("Invalid GoCardless credentials or expired token", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden, check the credentials have Bank Account Data enabled", :access_forbidden)
      when 404
        raise GocardlessError.new("Resource not found", :not_found)
      when 409
        data = parse_error_response_body(response)
        raise GocardlessError.new("Conflict from GoCardless API: #{response.body}", :conflict, response_data: data)
      when 429
        data = parse_error_response_body(response)
        raise GocardlessError.new(
          "GoCardless rate limit reached. Account data is limited to a few requests per day.",
          :rate_limited,
          response_data: data,
          retry_after: retry_after_seconds(response)
        )
      else
        data = parse_error_response_body(response)
        raise GocardlessError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed, response_data: data)
      end
    end

    # GoCardless signals the cooldown in a custom header rather than Retry-After, and the
    # account-scoped variant is the one that matters for per-account limits.
    def retry_after_seconds(response)
      value = response.headers["HTTP_X_RATELIMIT_ACCOUNT_SUCCESS_RESET"] ||
              response.headers["x-ratelimit-account-success-reset"] ||
              response.headers["retry-after"]

      value.presence&.to_i
    end

    def parse_error_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError
      { raw_body: response.body.to_s }
    end

    def parse_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error "GoCardless API: Failed to parse response: #{e.message}"
      raise GocardlessError.new("Failed to parse API response", :parse_error)
    end

    class GocardlessError < StandardError
      attr_reader :error_type, :response_data, :retry_after

      def initialize(message, error_type = :unknown, response_data: nil, retry_after: nil)
        super(message)
        @error_type = error_type
        @response_data = response_data
        @retry_after = retry_after
      end

      def rate_limited?
        error_type == :rate_limited
      end

      def credentials_invalid?
        error_type == :unauthorized || error_type == :access_forbidden
      end
    end
    class AuthenticationError < GocardlessError; end
end
