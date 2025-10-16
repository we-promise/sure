class Provider::EnableBanking < Provider
  # Subclass so errors caught in this provider are raised as Provider::EnableBanking::Error
  Error = Class.new(Provider::Error)

  def initialize(application_id:, certificate:, country_code:)
    @application_id = application_id
    @certificate = certificate
    @country_code = country_code
  end

  def get_redirect_urls
    result = with_provider_response do
      response = client.get("#{base_url}/application")
      JSON.parse(response.body).dig("redirect_urls")
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not fetch redirect URLs. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def get_available_aspsps(country_code: @country_code)
    result = with_provider_response do
      response = client.get("#{base_url}/aspsps") do |req|
        req.params["country"] = country_code
        req.params["psu_type"] = "personal" # Do not retrieve business accounts
      end
      JSON.parse(response.body).dig("aspsps")
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not fetch available ASPSPS for country #{country_code}. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def generate_authorization_url(aspsp_name, country_code, enable_banking_id)
    country_code ||= @country_code
    redirect_urls = get_redirect_urls
    redirect_url = redirect_urls&.first
    raise Error.new("No redirect URL configured") if redirect_url.blank?
    valid_until = Time.current + 90.days
    result = with_provider_response do
      body = {
        access: { valid_until: valid_until.utc.iso8601 },
        aspsp: { name: aspsp_name, country: country_code },
        state: enable_banking_id || SecureRandom.uuid,
        redirect_url: redirect_url
      }
      response = client.post("#{base_url}/auth", body.to_json)
      JSON.parse(response.body).dig("url")
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not generate authorization URL. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def create_session(auth_code)
    result = with_provider_response do
      body = { code: auth_code }
      response = client.post("#{base_url}/sessions", body.to_json)
      JSON.parse(response.body)
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not create session. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def get_account_details(account_id)
    result = with_provider_response do
      response = client.get("#{base_url}/accounts/#{account_id}/details")
      JSON.parse(response.body)
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not fetch account details. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def get_account_balances(account_id)
    result = with_provider_response do
      response = client.get("#{base_url}/accounts/#{account_id}/balances")
      JSON.parse(response.body).dig("balances")
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not fetch account balances. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def get_current_available_balance(account_id)
    balances = get_account_balances(account_id)
    balances = [] if balances.nil?
    balances_by_type = balances.group_by { |balance| balance["balance_type"] }
    available_balance = balances_by_type["ITAV"]&.first || balances_by_type["CLAV"]&.first
    current_balance = balances_by_type["ITBD"]&.first || balances_by_type["CLBD"]&.first
    {
      "available" => available_balance&.dig("balance_amount", "amount") || 0,
      "current" => current_balance&.dig("balance_amount", "amount") || 0
    }
  end

  def get_account_transactions(account_id, fetch_all, continuation_key: nil)
    result = with_provider_response do
      response = client.get("#{base_url}/accounts/#{account_id}/transactions") do |req|
        if !fetch_all
          req.params["date_from"] = 7.days.ago.to_date.iso8601
        else
          req.params["strategy"] = "longest"
        end
        if continuation_key
          req.params["continuation_key"] = continuation_key
        end
        req.params["transaction_status"] = "BOOK"
      end
      JSON.parse(response.body)
    end
    if result.success?
      result.data
    else
      Rails.logger.warn("Could not fetch account transactions. Provider error: #{result.error.message}")
      raise result.error
    end
  end

  def get_transactions(account_id, fetch_all)
    transactions = []
    continuation_key = nil
    loop do
      transaction_data = get_account_transactions(account_id, fetch_all, continuation_key: continuation_key)
      transactions.concat(transaction_data["transactions"] || [])
      continuation_key = transaction_data["continuation_key"]
      break if continuation_key.blank?
    end
    transactions
  end

  private
    attr_reader :application_id
    attr_reader :certificate

    def base_url
      "https://api.enablebanking.com"
    end

    def generate_jwt
      rsa_key = OpenSSL::PKey::RSA.new(certificate.gsub("\\n", "\n"))
      iat = Time.now.to_i
      exp = iat + 3600
      jwt_header = { typ: "JWT", alg: "RS256", kid: application_id }
      jwt_body = { iss: "enablebanking.com", aud: "api.enablebanking.com", iat: iat, exp: exp }
      token = JWT.encode(jwt_body, rsa_key, "RS256", jwt_header)
      @jwt_expires_at = Time.at(exp)
      token
    end

    def jwt
      if @jwt.nil? || Time.current >= (@jwt_expires_at - 60.seconds)
        @jwt = generate_jwt
      end
      @jwt
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Content-Type"] = "application/json"
        faraday.request :authorization, "Bearer", -> { jwt }
      end
    end
end
