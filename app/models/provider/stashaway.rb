# Client for the API behind StashAway's web app (api.stashaway.<region>,
# see Provider::Stashaway::Region). It is a private, undocumented interface: the login and GraphQL shapes here follow
# what the web app sends and may change without notice.
class Provider::Stashaway
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  # The token was rejected: it expired or was revoked, so the connection
  # needs a new sign-in.
  class AuthenticationError < Error; end
  # StashAway refused the email and password.
  class InvalidCredentials < Error; end
  # StashAway refused the SMS code.
  class InvalidCode < Error; end
  # StashAway asked for a verification flow other than the SMS code.
  class UnsupportedVerification < Error; end
  # StashAway stopped accepting the web-app version Sure identifies as.
  class UnsupportedClient < Error; end
  class RateLimited < Error; end
  # The request did not get through or came back unreadable.
  class TransientError < Error; end
  class ApiError < Error
    attr_reader :status_code

    def initialize(message, status_code: nil)
      super(message)
      @status_code = status_code
    end
  end
  # A GraphQL "not found" answer, which closed portfolios give for their detail.
  class NotFound < ApiError; end

  # Requests without a web-app client id it knows are refused with HTTP 426.
  CLIENT_ID = "webapp@4.4.0".freeze

  TRANSACTIONS_PAGE_SIZE = 100
  # A safety stop for the transaction walk, far above any real portfolio.
  MAX_TRANSACTION_PAGES = 200

  # Shown to the user when StashAway gives no reason of its own.
  MAX_MESSAGE_LENGTH = 200

  RETRYABLE_ERRORS = [ *HTTParty::COMMON_NETWORK_ERRORS, IOError, Zlib::Error ].uniq.freeze
  # The sign-in steps are not idempotent: a password or code StashAway has
  # processed must not go out again after a timeout or a lost answer, and a
  # repeated code send is another SMS. They are retried only after these
  # errors, which are raised before anything is sent and fail at once.
  UNSENT_REQUEST_ERRORS = [ Errno::ECONNREFUSED, SocketError ].freeze

  GOALS_QUERY = <<~GRAPHQL.squish.freeze
    query { goals(state: [ACTIVE, ARCHIVED, CLOSED]) { _id displayName goalType fundingSource state currency } }
  GRAPHQL

  GOAL_TRANSACTIONS_QUERY = <<~GRAPHQL.squish.freeze
    query ($goalId: ID!, $pageSize: Int, $page: Int) {
      goal(_id: $goalId) { _id transactions(pageSize: $pageSize, page: $page) { count items {
        id groupedDate groupedType groupedStatus
        transactions { id transactionType date: transactionDate description transactionStatus: status
          amount: signedValue { amount currency }
          metadata { securityCode fxRate operationId } } } } } }
  GRAPHQL

  GOAL_PERFORMANCE_QUERY = <<~GRAPHQL.squish.freeze
    query ($goalId: ID!, $displayCurrency: String) {
      goal(_id: $goalId) { portfolioPerformance(lookBackPeriod: INCEPTION, displayCurrency: $displayCurrency) {
        lastNavUpdate currency netAssetValueData { date amount } netDepositsData { date amount } } } }
  GRAPHQL

  # The answer to the password step. `token` authenticates the SMS code
  # steps; StashAway may also accept it as the API token straight away.
  # two_factor_required: StashAway accepted the password but wants the SMS
  # code first; token is then only good for sending and checking the code.
  Session = Data.define(:token, :user_id, :two_factor_required) do
    def initialize(token:, user_id: nil, two_factor_required: false) = super
  end

  default_options.merge!({ timeout: 60 }.merge(httparty_ssl_options))

  attr_reader :region, :token

  # region: a Provider::Stashaway::Region code; each region has its own host.
  def initialize(region:, token: nil)
    @region = Region.find(region)
    @token = token.presence
  end

  # The device id is the one the web app keeps per browser; StashAway ties
  # the SMS verification to it.
  #
  # An account with SMS verification gets HTTP 401 with message "2FA" and the
  # token for the code steps in the body, as StashAway's web app expects. A
  # 401 carrying "secondFactor" is StashAway's newer verification flow, which
  # Sure does not support.
  def login(email:, password:, device_id:)
    response = sign_in_post("/api/v2/auth/login", { email: email, password: password, userData: { deviceCookie: device_id } })

    if response.code == 401
      body = json_hash(response)
      raise UnsupportedVerification, "StashAway asks for a verification method Sure does not support yet" if body.key?("secondFactor")

      if body["message"] == "2FA"
        token = body["token"].presence
        raise ApiError.new("StashAway asked for an SMS code but did not return a session", status_code: 401) unless token

        return Session.new(token: token, user_id: body["userId"].presence&.to_s, two_factor_required: true)
      end
    end

    check_status!(response, step: :login)
    body = parse_body(response)
    session_token = body["token"].presence
    raise ApiError.new("StashAway did not return a session", status_code: 200) unless session_token

    Session.new(token: session_token, user_id: body["userId"].presence&.to_s, two_factor_required: false)
  end

  def send_two_factor_code(token:)
    post_json("/api/v1/auth/2fa/send", { token: token }, step: :send_code)
    true
  end

  # Returns the API token.
  def verify_two_factor(code:, token:, device_id:)
    body = post_json("/api/v1/auth/2fa", { secret: code.to_s.strip, token: token, userData: { deviceCookie: device_id } }, step: :verify_code)
    api_token = body["token"].presence
    raise ApiError.new("StashAway did not return a token for the code", status_code: 200) unless api_token

    api_token
  end

  # Whether StashAway serves portfolio data for this token. A refusal of any
  # kind other than an outage counts as no, so a sign-in that needs the SMS
  # code goes on to send it.
  def usable_token?(candidate)
    self.class.new(region: region.code, token: candidate).goals
    true
  rescue AuthenticationError, ApiError
    false
  end

  # An answer without the list is an error, not a connection without
  # portfolios: taken as empty, it would leave the accounts on their last
  # values with nothing to say why.
  def goals
    list = graphql("/goals", GOALS_QUERY)["goals"]
    raise ApiError.new("StashAway /goals answered without a goal list", status_code: 200) unless list.is_a?(Array)

    list
  end

  # Every grouped transaction item of a goal, in StashAway's order. Pages
  # count from 0. An item met on two pages, because the list shifted between
  # page requests, is kept once.
  def goal_transactions(goal_id)
    items = []
    seen = Set.new
    count = 0

    MAX_TRANSACTION_PAGES.times do |page|
      data = graphql("/transactions", GOAL_TRANSACTIONS_QUERY, goalId: goal_id, pageSize: TRANSACTIONS_PAGE_SIZE, page: page)
      transactions = data.dig("goal", "transactions")
      # Without the list and its count the answer says nothing about the
      # goal's transactions, and an empty list would read as none left.
      unless transactions.is_a?(Hash) && transactions["count"].is_a?(Integer)
        raise ApiError.new("StashAway goal #{goal_id} answered without a transaction list", status_code: 200)
      end

      batch = Array(transactions["items"])
      count = transactions["count"]
      batch.each { |item| items << item if item["id"].nil? || seen.add?(item["id"]) }
      return items if items.size >= count
      # The list ended short of its count: it changed while it was read, so
      # an item was missed. A shorter list would read as transactions that
      # no longer exist; the next sync reads the list afresh.
      raise ApiError.new("StashAway goal #{goal_id} lists #{count} transaction items; Sure read #{items.size} before the list ended", status_code: 200) if batch.empty?
    end

    raise ApiError.new("StashAway goal #{goal_id} lists #{count} transaction items; Sure read #{items.size} and stopped after #{MAX_TRANSACTION_PAGES} pages", status_code: 200)
  end

  # The goal's daily value and net deposits since inception, in `currency`.
  def goal_performance(goal_id, currency)
    performance = graphql("/goals", GOAL_PERFORMANCE_QUERY, goalId: goal_id, displayCurrency: currency).dig("goal", "portfolioPerformance") || {}

    {
      "nav" => Array(performance["netAssetValueData"]),
      "net_deposits" => Array(performance["netDepositsData"]),
      "last_nav_update" => performance["lastNavUpdate"],
      "currency" => performance["currency"]
    }
  end

  private

    def headers(authenticated: true)
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "x-client-identifier" => CLIENT_ID
      }.tap do |headers|
        headers["Authorization"] = "Bearer #{token}" if authenticated && token
      end
    end

    def graphql(path, query, variables = {})
      raise AuthenticationError, "StashAway is not signed in" unless token

      response = with_retries(path) do
        self.class.post("#{region.base_uri}/graphql#{path}", headers: headers, body: { query: query, variables: variables }.to_json)
      end
      check_status!(response, step: :data)

      body = parse_body(response)
      errors = Array(body["errors"])
      raise_graphql_error!(path, errors) if errors.any?

      data = body["data"]
      raise ApiError.new("StashAway #{path} answered without data", status_code: 200) unless data.is_a?(Hash)

      data
    end

    def raise_graphql_error!(path, errors)
      messages = errors.map { |error| error.is_a?(Hash) ? error["message"].to_s : error.to_s }
      message = "StashAway #{path}: #{messages.join("; ").truncate(MAX_MESSAGE_LENGTH)}"

      # Only a refusal of the session itself calls for a new sign-in; a bare
      # "forbidden" can be about one goal, and signing in again would not help.
      raise AuthenticationError, message if messages.any? { |m| m.match?(/unauthori[sz]ed|unauthenticated|jwt|token (has )?expired/i) }
      raise NotFound.new(message, status_code: 200) if messages.any? { |m| m.match?(/not found/i) }

      raise ApiError.new(message, status_code: 200)
    end

    def post_json(path, payload, step:)
      response = sign_in_post(path, payload)
      check_status!(response, step: step)

      parse_body(response)
    end

    # Login steps send no Bearer token: their tokens travel in the body.
    def sign_in_post(path, payload)
      with_retries(path, retry_on: UNSENT_REQUEST_ERRORS, max_attempts: 2) do
        self.class.post("#{region.base_uri}#{path}", headers: headers(authenticated: false), body: payload.to_json)
      end
    end

    def check_status!(response, step:)
      code = response.code
      return if (200..299).cover?(code)

      raise UnsupportedClient, "StashAway no longer accepts the web-app version Sure uses (#{CLIENT_ID}); Sure needs an update" if code == 426
      raise RateLimited, "StashAway is limiting requests; try again in a few minutes" if code == 429
      raise TransientError, "StashAway is unavailable (HTTP #{code})" if code >= 500

      if code.in?([ 400, 401, 403, 422 ])
        case step
        when :login then raise InvalidCredentials, provider_message(response) || "StashAway did not accept the email and password"
        when :verify_code then raise InvalidCode, provider_message(response) || "StashAway did not accept the code"
        else
          raise AuthenticationError, "StashAway sign-in has expired (HTTP #{code})" if code.in?([ 401, 403 ])
        end
      end

      raise ApiError.new("StashAway request failed (HTTP #{code})", status_code: code)
    end

    def json_hash(response)
      body = JSON.parse(response.body.to_s)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    # StashAway's own reason for refusing a login step, such as a wrong
    # password, when it gives one.
    def provider_message(response)
      body = JSON.parse(response.body.to_s)
      message = body.is_a?(Hash) ? (body["message"] || body["error"]) : nil
      message.is_a?(String) ? message.squish.truncate(MAX_MESSAGE_LENGTH).presence : nil
    rescue JSON::ParserError
      nil
    end

    def parse_body(response)
      body = response.parsed_response
      body = JSON.parse(body) if body.is_a?(String)
      raise TransientError, "StashAway returned an unexpected response" unless body.is_a?(Hash)

      body
    rescue JSON::ParserError
      raise TransientError, "StashAway returned a response that is not JSON"
    end

    def with_retries(label, retry_on: RETRYABLE_ERRORS, max_attempts: 3)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue *RETRYABLE_ERRORS => e
        retryable = attempt < max_attempts && retry_on.any? { |error| e.is_a?(error) }
        raise TransientError, "StashAway #{label} request failed: #{e.class}" unless retryable

        sleep(2**attempt)
        retry
      end
    end
end
