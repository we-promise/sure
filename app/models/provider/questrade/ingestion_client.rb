require "bigdecimal"
require "json"
require "time"
require "uri"

# A separate reader keeps the legacy authentication callbacks intact. The store
# is an application-bound capability, never a credential hash or an optional
# callback. It must serialize every consumer of this grant (including legacy
# jobs), reload credentials under that lock, and commit each session mutation
# independently of any ingestion transaction before returning.
#
# with_session_lock yields a session with credentials, refresh_pending?,
# begin_refresh!, persist_credentials!(hash), and mark_refresh_uncertain!.
# begin_refresh! durably records intent BEFORE the single-use HTTP exchange.
# An interrupted exchange stays pending and requires reauthorization; it must
# never be retried with the old refresh token. Successful persistence clears it.
class Provider::Questrade::IngestionClient
  MAX_ROWS = 20_000
  MAX_RESPONSE_BYTES = 20.megabytes
  NETWORK_ERRORS = [ SocketError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET,
    Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError ].freeze

  def initialize(credential_store:, clock: -> { Time.current }, environment: "live")
    unless credential_store.respond_to?(:with_session_lock) && %w[live practice].include?(environment)
      raise Provider::Questrade::ConfigurationError, "Questrade requires a durable credential session store"
    end
    @credential_store, @clock, @environment = credential_store, clock, environment
  end

  def get_ingestion_accounts
    collection(read("accounts"), :accounts)
  end

  def get_ingestion_holdings(account_id:)
    collection(read("accounts/#{identifier(account_id)}/positions"), :positions)
  end

  def get_ingestion_balances(account_id:)
    response = read("accounts/#{identifier(account_id)}/balances")
    collection(response, :perCurrencyBalances)
    collection(response, :combinedBalances)
  end

  def get_ingestion_symbols(ids:)
    raise ArgumentError unless ids.is_a?(Array) && ids.size <= 100
    values = ids.map { |id| identifier(id) }.uniq
    return { symbols: [] }.with_indifferent_access if values.empty?
    collection(read("symbols", query: { ids: values.join(",") }), :symbols)
  rescue ArgumentError
    raise Provider::Questrade::Error.new("Invalid Questrade symbol request", :invalid_request), cause: nil
  end

  # Exactly one bounded request. The adapter owns continuation across dates.
  def get_ingestion_activities(account_id:, start_time:, end_time:)
    from, to = Time.iso8601(start_time), Time.iso8601(end_time)
    raise ArgumentError unless from <= to && to - from < 31.days
    collection(read("accounts/#{identifier(account_id)}/activities", query: { startTime: from.utc.iso8601(6), endTime: to.utc.iso8601(6) }), :activities)
  rescue ArgumentError, TypeError
    raise Provider::Questrade::Error.new("Invalid Questrade activity window", :invalid_request), cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def session_credentials(rejected_token: nil)
      @credential_store.with_session_lock do |session|
        if session.refresh_pending?
          raise Provider::Questrade::AuthenticationError.new("Questrade token exchange requires recovery", :refresh_uncertain)
        end
        credentials = session.credentials.with_indifferent_access
        unless credentials[:environment].nil? || credentials[:environment] == @environment
          raise Provider::Questrade::ConfigurationError, "Questrade credential environment differs"
        end
        valid = bearer_token?(credentials[:access_token]) &&
          credentials[:expires_at].is_a?(String) && Time.iso8601(credentials[:expires_at]) > @clock.call + Provider::Questrade::ACCESS_TOKEN_SKEW
        if valid && credentials[:access_token] != rejected_token
          api_base(credentials.fetch(:api_server))
          credentials.slice(:access_token, :api_server)
        else
          exchange(session, credentials)
        end
      end
    rescue ArgumentError, TypeError, KeyError, NoMethodError
      raise Provider::Questrade::ConfigurationError.new("Invalid Questrade credential session", :invalid_credentials), cause: nil
    end

    def exchange(session, credentials)
      token = credentials[:refresh_token]
      unless token.is_a?(String) && token.present?
        raise Provider::Questrade::AuthenticationError.new("Questrade authorization is required", :reauth_required)
      end
      session.begin_refresh!
      begin
        # No retry: a timeout, 5xx or process crash can follow a consumed token.
        login = @environment == "practice" ? "https://practicelogin.questrade.com/oauth2/token" : Provider::Questrade::LOGIN_URL
        response = HTTParty.post(login, body: { grant_type: "refresh_token", refresh_token: token },
          timeout: 120, follow_redirects: false, verify: true)
        unless response.code.to_i == 200
          raise Provider::Questrade::AuthenticationError.new("Questrade token exchange did not complete", :refresh_uncertain)
        end
        body = parsed_object(response.body)
        unless %i[access_token refresh_token api_server].all? { |key| body[key].is_a?(String) && body[key].present? } &&
            bearer_token?(body[:access_token]) &&
            body[:expires_in].is_a?(Integer) && body[:expires_in] > Provider::Questrade::ACCESS_TOKEN_SKEW &&
            body[:token_type].to_s.casecmp("Bearer").zero?
          raise Provider::Questrade::AuthenticationError.new("Invalid Questrade token exchange", :refresh_uncertain)
        end
        api_base(body[:api_server])
        values = credentials.stringify_keys.merge("refresh_token" => body[:refresh_token], "access_token" => body[:access_token],
          "api_server" => body[:api_server], "expires_at" => (@clock.call + body[:expires_in]).utc.iso8601(6),
          "environment" => @environment)
        values["scope"] = body[:scope] if body[:scope].is_a?(String)
        # Never return/use the access token until the rotated credentials commit.
        session.persist_credentials!(values)
        values.with_indifferent_access.slice(:access_token, :api_server)
      rescue Provider::AccountData::StaleWriter, Provider::AccountData::CredentialStore::Busy,
          Provider::AccountData::CredentialStore::ReauthorizationRequired
        raise
      rescue StandardError
        begin
          session.mark_refresh_uncertain!
        rescue StandardError
          # The committed pre-request intent still prevents reuse if recording
          # the more specific failure state is temporarily unavailable.
        end
        raise Provider::Questrade::AuthenticationError.new("Questrade token exchange requires recovery", :refresh_uncertain), cause: nil
      end
    end

    def read(path, query: {})
      credentials = session_credentials
      response = data_request(path, query, credentials)
      if response.code.to_i == 401
        credentials = session_credentials(rejected_token: credentials.fetch(:access_token))
        response = data_request(path, query, credentials)
      end
      case response.code.to_i
      when 200 then parsed_object(response.body)
      when 401 then raise Provider::Questrade::AuthenticationError.new("Questrade authorization is required", :reauth_required)
      when 403 then raise Provider::Questrade::AuthenticationError.new("Questrade account-read permission is required", :insufficient_scope)
      when 429 then raise Provider::Questrade::Error.new("Questrade request was rate limited", :rate_limited)
      else raise Provider::Questrade::Error.new("Questrade account read failed", :api_error)
      end
    end

    def data_request(path, query, credentials)
      attempts = 0
      begin
        attempts += 1
        HTTParty.get("#{api_base(credentials.fetch(:api_server))}/v1/#{path}", query: query,
          headers: { "Authorization" => "Bearer #{credentials.fetch(:access_token)}", "Accept" => "application/json" },
          timeout: 120, follow_redirects: false, verify: true)
      rescue *NETWORK_ERRORS
        if attempts < 4
          sleep(2**attempts)
          retry
        end
        raise Provider::Questrade::Error.new("Questrade account read is unavailable", :network_error), cause: nil
      rescue OpenSSL::SSL::SSLError
        raise Provider::Questrade::Error.new("Questrade TLS validation failed", :tls_error), cause: nil
      end
    end

    def bearer_token?(value)
      value.is_a?(String) && value.present? && !value.match?(/[[:space:][:cntrl:]]/)
    end

    def api_base(value)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host&.match?(/\A[a-z0-9-]+\.iq\.questrade\.com\z/i) &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/", "/v1", "/v1/" ].include?(uri.path)
        raise ArgumentError
      end
      "https://#{uri.host}"
    rescue URI::InvalidURIError, ArgumentError, TypeError
      raise Provider::Questrade::ConfigurationError.new("Invalid Questrade API server", :invalid_server), cause: nil
    end

    def identifier(value)
      raise ArgumentError unless (value.is_a?(String) || value.is_a?(Integer)) && value.to_s.match?(/\A\d+\z/)
      value.to_s
    rescue ArgumentError
      raise Provider::Questrade::Error.new("Invalid Questrade identifier", :invalid_request), cause: nil
    end

    def parsed_object(body)
      raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_RESPONSE_BYTES
      result = JSON.parse(body, decimal_class: BigDecimal)
      raise ArgumentError unless result.is_a?(Hash)
      result.with_indifferent_access
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Provider::Questrade::Error.new("Invalid Questrade response", :invalid_response), cause: nil
    end

    def collection(response, key)
      rows = response[key]
      unless rows.is_a?(Array) && rows.size <= MAX_ROWS && rows.all? { |row| row.is_a?(Hash) } &&
          %i[next nextPage next_cursor continuationToken error].none? { |field| response[field].present? } &&
          response[:hasMore] != true && (!response.key?(:totalCount) || response[:totalCount] == rows.size)
        raise Provider::Questrade::Error.new("Incomplete Questrade response", :invalid_response)
      end
      response
    end
end
