class Provider::Gocardless
  BASE_URL = "https://bankaccountdata.gocardless.com/api/v2"

  class Autherror < StandardError; end
  class Apierror < StandardError; end

  def initialize(secret_id, secret_key)
    @secret_id  = secret_id
    @secret_key = secret_key
    @access_token = nil
  end

  # Exchange secret_id + secret_key for tokens
  def new_token
    post("/token/new/", { secret_id: @secret_id, secret_key: @secret_key }, authenticated: false)
  end

  # Exchange refresh token for a new 24h access token
  def refresh_access_token(refresh_token)
    post("/token/refresh/", { refresh: refresh_token }, authenticated: false)
  end

  # List all banks for a country (default GB)
  def institutions(country: "gb")
    get("/institutions/?country=#{country}")
  end

  # Create a 90-day end user agreement
  def create_agreement(institution_id)
    post("/agreements/enduser/", {
      institution_id:        institution_id,
      max_historical_days:   730,
      access_valid_for_days: 90,
      access_scope:          [ "details", "balances", "transactions" ]
    })
  end

  # Create a requisition (returns the bank auth link)
  def create_requisition(institution_id:, agreement_id:, redirect_url:, reference:)
    post("/requisitions/", {
      institution_id: institution_id,
      agreement:      agreement_id,
      redirect:       redirect_url,
      reference:      reference,
      user_language:  "EN"
    })
  end

  # Get requisition status + account IDs after user authenticates
  def get_requisition(requisition_id)
    get("/requisitions/#{requisition_id}/")
  end

  # Get account metadata (name, IBAN, currency)
  def account_details(account_id)
    get("/accounts/#{account_id}/details/")
  end

  # Get current balance
  def balances(account_id)
    get("/accounts/#{account_id}/balances/")
  end

  # Get booked transactions (last 90 days by default)
  def transactions(account_id, date_from: 90.days.ago.to_date)
    get("/accounts/#{account_id}/transactions/?date_from=#{date_from}")
  end

  # Set the access token directly (used after token refresh)
  def with_token(token)
    @access_token = token
    self
  end

  private

    def get(path)
      response = connection.get("#{BASE_URL}#{path}") do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}" if @access_token
      end
      handle_response(response)
    end

    def post(path, body, authenticated: true)
      response = connection.post("#{BASE_URL}#{path}") do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}" if authenticated && @access_token
        req.body = body.to_json
      end
      handle_response(response)
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.headers["Content-Type"] = "application/json"
        f.headers["Accept"]       = "application/json"
      end
    end

    def handle_response(response)
      case response.status
      when 200..299
        JSON.parse(response.body)
      when 401
        raise Autherror, "GoCardless authentication failed — check your secret_id and secret_key"
      else
        raise Apierror, "GoCardless API error #{response.status}: #{response.body}"
      end
    end
end