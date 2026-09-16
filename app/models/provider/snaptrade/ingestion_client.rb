require "base64"
require "bigdecimal"
require "date"
require "json"
require "time"
require "uri"

# Exact, bounded OAuth data reads. This client has no dependency on a legacy
# item: credential rotation is committed through the injected shared store.
class Provider::Snaptrade::IngestionClient
  PAGE_SIZE = 500
  MAX_BODY_BYTES = 20.megabytes

  def initialize(credential_store:, oauth_client_id:, oauth_client_secret: nil, clock: -> { Time.now.utc }, connection: nil)
    unless credential_store.respond_to?(:with_session_lock) && oauth_client_id.is_a?(String) && oauth_client_id.present? &&
        (oauth_client_secret.nil? || oauth_client_secret.is_a?(String))
      raise Provider::Snaptrade::ConfigurationError, "SnapTrade OAuth configuration is incomplete"
    end
    @credential_store, @client_id, @client_secret, @clock = credential_store, oauth_client_id, oauth_client_secret, clock
    @connection = connection || Faraday.new do |faraday|
      faraday.options.timeout = 30
      faraday.options.open_timeout = 10
    end
  end

  def accounts_snapshot
    get("/accounts")
  end

  def authorizations_snapshot
    get("/authorizations")
  end

  def account_snapshot(account_id:)
    get("/accounts/#{path_id(account_id)}")
  end

  def balances_snapshot(account_id:)
    get("/accounts/#{path_id(account_id)}/balances")
  end

  def positions_snapshot(account_id:)
    get("/accounts/#{path_id(account_id)}/positions/all")
  end

  # Canonical paths replace the deprecated /api/v1 prefix. Pagination is
  # explicit: https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_getAccountActivities
  def activities_page(account_id:, start_date:, end_date:, offset: 0)
    raise ArgumentError unless offset.is_a?(Integer) && offset.between?(0, 2_147_483_647)
    first, last = Date.iso8601(start_date), Date.iso8601(end_date)
    raise ArgumentError if first > last
    get("/accounts/#{path_id(account_id)}/activities", startDate: first.iso8601, endDate: last.iso8601,
      offset: offset, limit: PAGE_SIZE)
  end

  # Kept for the legacy sparse-history fallback; the adapter owns whether its
  # response is demonstrably complete. No unbounded loop occurs in the client.
  def activities_fallback_snapshot(account_id:, start_date:, end_date:)
    first, last = Date.iso8601(start_date), Date.iso8601(end_date)
    raise ArgumentError if first > last
    get("/activities", accounts: path_id(account_id), startDate: first.iso8601, endDate: last.iso8601)
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def get(path, params = {})
      token = access_token
      response = data_request(path, params, token)
      if response.status == 401
        token = access_token(rejected_token: token)
        response = data_request(path, params, token)
      end
      unless response.success?
        raise Provider::Snaptrade::AuthenticationError, "SnapTrade authorization rejected" if response.status == 401
        raise Provider::Snaptrade::ApiError.new("SnapTrade data request failed", status_code: response.status)
      end
      parse(response.body)
    rescue Faraday::Error, Errno::ECONNRESET, Errno::ETIMEDOUT
      raise Provider::Snaptrade::ApiError, "SnapTrade data request unavailable", cause: nil
    end

    def data_request(path, params, token)
      @connection.get("#{Provider::Snaptrade::API_BASE_URL}#{path}") do |request|
        request.headers["Authorization"] = "Bearer #{token}"
        request.headers["Accept"] = "application/json"
        request.params.update(params)
      end
    end

    def access_token(rejected_token: nil)
      @credential_store.with_session_lock do |session|
        values = session.credentials
        if session.refresh_pending?
          raise Provider::AccountData::CredentialStore::ReauthorizationRequired, "Previous SnapTrade rotation needs reauthorization"
        end
        token = values["oauth_access_token"]
        unless bearer_token?(token)
          # Historical SDK credentials remain encrypted in storage, but the
          # current integration no longer supports that authentication mode.
          raise Provider::Snaptrade::AuthenticationError, "SnapTrade OAuth reconnection is required"
        end
        expiry = values["oauth_token_expires_at"]
        fresh = expiry.blank? || Time.iso8601(expiry) > @clock.call + 60
        needs_refresh = rejected_token ? token == rejected_token : !fresh
        return token unless needs_refresh
        refresh_token = values["oauth_refresh_token"]
        unless refresh_token.is_a?(String) && refresh_token.present?
          raise Provider::Snaptrade::AuthenticationError, "SnapTrade OAuth refresh token is missing"
        end

        session.begin_refresh!
        begin
          # A response can be lost after single-use rotation succeeds upstream.
          # Never replay this request, and never publish a token before commit.
          payload = refresh(refresh_token)
          replacement = values.merge("oauth_access_token" => payload.fetch("access_token"))
          %w[refresh_token token_type scope].each do |key|
            replacement["oauth_#{key}"] = payload[key] if payload[key].present?
          end
          if payload["expires_in"].present?
            lifetime = Integer(payload["expires_in"].to_s, 10)
            raise ArgumentError unless lifetime.positive?
            replacement["oauth_token_expires_at"] = (@clock.call + lifetime).iso8601(9)
          end
          session.persist_credentials!(replacement)
          replacement.fetch("oauth_access_token")
        rescue StandardError
          begin
            session.mark_refresh_uncertain!
          rescue StandardError
            # The committed intent still prevents reuse if marking uncertainty
            # fails, including an authorization change while HTTP was running.
          end
          raise Provider::Snaptrade::AuthenticationError, "SnapTrade token rotation requires reauthorization", cause: nil
        end
      end
    rescue ArgumentError, TypeError
      raise Provider::Snaptrade::AuthenticationError, "SnapTrade token metadata is invalid", cause: nil
    end

    def refresh(token)
      params = { grant_type: "refresh_token", refresh_token: token }
      params[:client_id] = @client_id if @client_secret.blank?
      response = @connection.post(Provider::Snaptrade::TOKEN_URL) do |request|
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        if @client_secret.present?
          request.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{@client_id}:#{@client_secret}")}"
        end
        request.body = URI.encode_www_form(params)
      end
      raise Provider::Snaptrade::AuthenticationError, "SnapTrade token exchange rejected" unless response.success?
      payload = parse(response.body)
      unless payload.is_a?(Hash) && bearer_token?(payload["access_token"]) &&
          (payload["refresh_token"].blank? || bearer_token?(payload["refresh_token"])) &&
          (payload["scope"].nil? || payload["scope"].is_a?(String)) &&
          (payload["token_type"].blank? || payload["token_type"].to_s.casecmp("Bearer").zero?)
        raise Provider::Snaptrade::AuthenticationError, "SnapTrade token response incomplete"
      end
      payload
    end

    def parse(body)
      raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES
      JSON.parse(body, decimal_class: BigDecimal)
    rescue JSON::ParserError, ArgumentError
      raise Provider::Snaptrade::ApiError, "SnapTrade response is invalid", cause: nil
    end

    def path_id(value)
      unless value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_-]{1,200}\z/)
        raise ArgumentError, "Invalid SnapTrade account identity"
      end
      value
    end

    def bearer_token?(value)
      value.is_a?(String) && value.present? && !value.match?(/[[:space:][:cntrl:]]/)
    end
end
