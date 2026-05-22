# Sophtron API client for account aggregation.
#
# Sophtron uses two API shapes:
# - V2 REST endpoints for customer provisioning.
# - V1 RPC-style endpoints for institution connection, jobs, MFA, accounts, and transactions.
class Provider::Sophtron < Provider
  include HTTParty

  DEFAULT_BASE_URL = "https://api.sophtron.com/api"
  USER_AGENT = "Sure Finance Sophtron Client"
  FAILURE_JOB_STATUSES = %w[Completed Timeout Failed Failure Error].freeze

  headers "User-Agent" => USER_AGENT
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  Error = Class.new(Provider::Error) do
    attr_reader :error_type

    def initialize(message, error_type = :unknown, details: nil)
      @error_type = error_type
      super(message, details: details)
    end
  end

  attr_reader :user_id, :access_key, :base_url

  def initialize(user_id, access_key, base_url: DEFAULT_BASE_URL)
    @user_id = user_id
    @access_key = access_key
    @base_url = normalize_base_url(base_url)
    super()
  end

  def auth_header_for(method, api_path)
    auth_path = self.class.auth_path(api_path)
    plain_key = "#{method.to_s.upcase}\n#{auth_path}"
    key_bytes = Base64.decode64(access_key.to_s)
    raise ArgumentError, "decoded key is empty" if key_bytes.blank?
    signature = OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), key_bytes, plain_key)
    "FIApiAUTH:#{user_id}:#{Base64.strict_encode64(signature)}:#{auth_path}"
  rescue ArgumentError => e
    raise Error.new("Invalid Sophtron Access Key: #{e.message}", :invalid_access_key)
  end

  def self.auth_path(api_path)
    path = URI.parse(api_path.to_s).path
    last_segment = path.to_s.split("/").last.to_s
    "/#{last_segment}".downcase
  rescue URI::InvalidURIError
    last_segment = api_path.to_s.split("?").first.to_s.split("/").last.to_s
    "/#{last_segment}".downcase
  end

  def self.job_success?(job)
    job = job.with_indifferent_access
    job[:SuccessFlag] == true || job[:success_flag] == true || job[:LastStatus].to_s == "AccountsReady" || job[:last_status].to_s == "AccountsReady"
  end

  def self.job_failed?(job)
    job = job.with_indifferent_access
    success_flag = job.key?(:SuccessFlag) ? job[:SuccessFlag] : job[:success_flag]
    last_status = job[:LastStatus] || job[:last_status]
    success_flag == false && failure_job_status?(last_status)
  end

  def self.job_completed?(job)
    job = job.with_indifferent_access
    (job[:LastStatus] || job[:last_status]).to_s == "Completed" && !job_failed?(job)
  end

  def self.failure_job_status?(last_status)
    status = last_status.to_s
    FAILURE_JOB_STATUSES.include?(status) || status.match?(/timeout|fail|error/i)
  end

  def self.job_requires_input?(job)
    job = job.with_indifferent_access
    job[:SecurityQuestion].present? ||
      job[:security_question].present? ||
      job[:TokenMethod].present? ||
      job[:token_method].present? ||
      job_token_input_required?(job) ||
      job[:TokenRead].present? ||
      job[:token_read].present? ||
      job[:CaptchaImage].present? ||
      job[:captcha_image].present?
  end

  def self.job_token_input_required?(job)
    job = job.with_indifferent_access
    token_input = job[:TokenInput] || job[:token_input]
    token_input.blank? && (
      job[:TokenSentFlag] == true ||
      job[:token_sent_flag] == true ||
      job[:TokenInputName].present? ||
      job[:token_input_name].present? ||
      job[:LastStep].to_s == "TokenInput" ||
      job[:last_step].to_s == "TokenInput"
    )
  end

  def self.parse_json_array(value)
    return [] if value.blank?
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : Array(parsed)
  rescue JSON::ParserError
    Array(value)
  end

  def self.response_data!(response)
    return response unless response.respond_to?(:success?) && response.respond_to?(:data)
    return response.data if response.success?

    raise response.error || Error.new("Sophtron provider response did not include data", :invalid_response)
  end

  # GET /api/Institution/HealthCheckAuth
  def health_check_auth
    with_provider_response do
      request(:get, "/Institution/HealthCheckAuth", parse_json: false)
    end
  end

  # GET /api/v2/customers
  def list_customers
    with_provider_response do
      parsed = request(:get, "/v2/customers")
      extract_array_response(parsed, :customers, :Customers)
    end
  end

  # POST /api/v2/customers
  def create_customer(unique_id:, name:, source: "Sure")
    with_provider_response do
      request(
        :post,
        "/v2/customers",
        body: {
          UniqueID: unique_id,
          Name: name,
          Source: source
        }
      )
    end
  end

  # POST /api/Institution/GetInstitutionByName
  def search_institutions(institution_name)
    with_provider_response do
      parsed = request(
        :post,
        "/Institution/GetInstitutionByName",
        body: { InstitutionName: institution_name.to_s }
      )
      extract_array_response(parsed, :institutions, :Institutions)
    end
  end

  # POST /api/UserInstitution/GetUserInstitutionsByUser
  def list_user_institutions
    with_provider_response do
      parsed = request(
        :post,
        "/UserInstitution/GetUserInstitutionsByUser",
        body: { UserID: user_id }
      )
      extract_array_response(parsed, :user_institutions, :UserInstitutions)
    end
  end

  # POST /api/UserInstitution/CreateUserInstitution
  def create_user_institution(institution_id:, username:, password:, pin: "")
    with_provider_response do
      request(
        :post,
        "/UserInstitution/CreateUserInstitution",
        body: {
          UserID: user_id,
          InstitutionID: institution_id,
          UserName: username,
          Password: password,
          PIN: pin.to_s
        }
      )
    end
  end

  # POST /api/Job/GetJobInformationByID
  def get_job_information(job_id)
    with_provider_response do
      fetch_job_information(job_id)
    end
  end

  # POST /api/Job/UpdateJobSecurityAnswer
  def update_job_security_answer(job_id, answers)
    security_answer = answers.is_a?(String) ? answers : Array(answers).to_json

    with_provider_response do
      request(
        :post,
        "/Job/UpdateJobSecurityAnswer",
        body: { JobID: job_id, SecurityAnswer: security_answer }
      )
    end
  end

  # POST /api/Job/UpdateJobTokenInput
  def update_job_token_input(job_id, token_choice: nil, token_input: nil, verify_phone_flag: nil)
    with_provider_response do
      request(
        :post,
        "/Job/UpdateJobTokenInput",
        body: {
          JobID: job_id,
          TokenChoice: token_choice,
          TokenInput: token_input,
          VerifyPhoneFlag: verify_phone_flag
        }
      )
    end
  end

  # POST /api/Job/UpdateJobCaptcha
  def update_job_captcha(job_id, captcha_input)
    with_provider_response do
      request(
        :post,
        "/Job/UpdateJobCaptcha",
        body: { JobID: job_id, CaptchaInput: captcha_input }
      )
    end
  end

  # POST /api/UserInstitution/GetUserInstitutionAccounts
  def get_user_institution_accounts(user_institution_id)
    with_provider_response do
      fetch_user_institution_accounts(user_institution_id)
    end
  end

  def get_accounts(user_institution_id)
    with_provider_response do
      accounts = fetch_user_institution_accounts(user_institution_id)
      normalized = accounts.map { |account| normalize_account(account, user_institution_id: user_institution_id) }
      { accounts: normalized, total: normalized.size }
    end
  end

  # POST /api/UserInstitutionAccount/RefreshUserInstitutionAccount
  def refresh_account(account_id)
    with_provider_response do
      request(
        :post,
        "/UserInstitutionAccount/RefreshUserInstitutionAccount",
        body: { AccountID: account_id }
      )
    end
  end

  # POST /api/Transaction/GetTransactionsByTransactionDate
  def get_account_transactions(account_id, start_date: nil, end_date: nil)
    with_provider_response do
      parsed = request(
        :post,
        "/Transaction/GetTransactionsByTransactionDate",
        body: {
          AccountID: account_id,
          StartDate: (start_date || 120.days.ago).to_date.to_s,
          EndDate: (end_date || Date.tomorrow).to_date.to_s
        }
      )

      raw_transactions = extract_array_response(parsed, :transactions, :Transactions)
      transactions = raw_transactions.map { |transaction| normalize_transaction(transaction, account_id) }

      { transactions: transactions, total: transactions.size }
    end
  end

  def poll_job(job_id, **)
    get_job_information(job_id)
  end

  private

    def default_error_transformer(error)
      return error if error.is_a?(Error)

      super
    end

    def fetch_job_information(job_id)
      request(
        :post,
        "/Job/GetJobInformationByID",
        body: { JobID: job_id }
      )
    end

    def fetch_user_institution_accounts(user_institution_id)
      parsed = request(
        :post,
        "/UserInstitution/GetUserInstitutionAccounts",
        body: { UserInstitutionID: user_institution_id }
      )
      extract_array_response(parsed, :accounts, :Accounts)
    end

    def extract_array_response(parsed, *keys)
      return parsed if parsed.is_a?(Array)
      return [] if parsed.respond_to?(:empty?) && parsed.empty?

      if parsed.respond_to?(:with_indifferent_access)
        parsed = parsed.with_indifferent_access
        keys.each do |key|
          return Array(parsed[key]) if parsed.key?(key)
        end
      end

      raise Error.new("Invalid Sophtron response format", :invalid_response, details: parsed)
    end

    def request(method, api_path, body: nil, parse_json: true)
      options = { headers: auth_headers(method: method, api_path: api_path) }
      options[:body] = body.to_json if body

      response = self.class.public_send(method, "#{base_url}#{api_path}", options)
      handle_response(response, parse_json: parse_json)
    rescue Error
      raise
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise Error.new("Sophtron request failed: #{e.message}", :request_failed)
    rescue StandardError => e
      raise Error.new("Sophtron request failed: #{e.message}", :request_failed)
    end

    def auth_headers(method:, api_path:)
      {
        "Authorization" => auth_header_for(method, api_path),
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response, parse_json: true)
      body = response.body.to_s

      case response.code.to_i
      when 200, 201, 204
        return {} if body.strip.blank?

        parse_json ? JSON.parse(body, symbolize_names: true) : parse_optional_json(body)
      when 400
        raise Error.new("Bad request to Sophtron API: #{body}", :bad_request, details: body)
      when 401
        raise Error.new("Invalid Sophtron User ID or Access Key", :unauthorized, details: body)
      when 403
        raise Error.new("Access forbidden by Sophtron", :access_forbidden, details: body)
      when 404
        raise Error.new("Sophtron resource not found", :not_found, details: body)
      when 429
        raise Error.new("Sophtron rate limit exceeded. Please try again later.", :rate_limited, details: body)
      else
        raise Error.new(
          "Sophtron API request failed: #{response.code} #{response.message} - #{body}",
          :fetch_failed,
          details: body
        )
      end
    rescue JSON::ParserError => e
      raise Error.new("Invalid JSON response from Sophtron API: #{e.message}", :invalid_response, details: body)
    end

    def parse_optional_json(body)
      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      body
    end

    def normalize_base_url(value)
      url = value.presence || DEFAULT_BASE_URL
      url = url.to_s.chomp("/")
      url = url.delete_suffix("/v2") if url.end_with?("/v2")

      parsed = URI.parse(url)
      parsed.path.to_s.end_with?("/api") ? url : "#{url}/api"
    rescue URI::InvalidURIError
      DEFAULT_BASE_URL
    end

    def normalize_account(account, user_institution_id:)
      account = account.with_indifferent_access
      account_id = first_present(account, :AccountID, :account_id, :id)
      account_name = first_present(account, :AccountName, :account_name, :name)
      account_number = first_present(account, :AccountNumber, :account_number)
      currency = first_present(account, :BalanceCurrency, :balance_currency, :Currency, :currency).presence || "USD"

      {
        id: account_id,
        account_id: account_id,
        account_name: account_name,
        name: account_name,
        account_type: first_present(account, :AccountType, :account_type, :type).presence || "unknown",
        sub_type: first_present(account, :AccountSubType, :account_sub_type, :SubType, :sub_type).presence || "unknown",
        balance: first_present(account, :AccountBalance, :account_balance, :Balance, :balance),
        balance_currency: currency,
        currency: currency,
        account_number_mask: mask_account_number(account_number),
        status: first_present(account, :AccountStatus, :account_status, :Status, :status).presence || "active",
        user_institution_id: user_institution_id,
        institution_name: first_present(account, :InstitutionName, :institution_name),
        raw_payload: account.to_h
      }.with_indifferent_access
    end

    def normalize_transaction(transaction, account_id)
      transaction = transaction.with_indifferent_access

      {
        id: first_present(transaction, :TransactionID, :TransactionId, :transaction_id, :transactionId, :ID, :id),
        accountId: account_id,
        type: first_present(transaction, :Type, :type).presence || "unknown",
        status: first_present(transaction, :Status, :status).presence || "completed",
        amount: first_present(transaction, :Amount, :amount).presence || 0,
        currency: first_present(transaction, :Currency, :currency).presence || "USD",
        date: first_present(transaction, :TransactionDate, :transaction_date, :Date, :date),
        merchant: first_present(transaction, :Merchant, :merchant).presence || extract_merchant(first_present(transaction, :Description, :description)).presence || "",
        description: first_present(transaction, :Description, :description).presence || ""
      }.with_indifferent_access
    end

    def first_present(hash, *keys)
      keys.each do |key|
        value = hash[key]
        return value if value.present?
      end

      nil
    end

    def mask_account_number(account_number)
      return nil if account_number.blank?

      last_four = account_number.to_s.gsub(/\s+/, "").last(4)
      last_four.present? ? "****#{last_four}" : nil
    end

    def extract_merchant(line)
      return nil if line.nil?

      line = line.to_s.strip
      return nil if line.empty?

      if line =~ /INSUFFICIENT FUNDS FEE/i
        "Bank Fee: Insufficient Funds"
      elsif line =~ /OVERDRAFT PROTECTION/i
        "Bank Transfer: Overdraft Protection"
      elsif line =~ /AUTO PAY WF HOME MTG/i
        "Wells Fargo Home Mortgage"
      elsif line =~ /PAYDAY LOAN/i
        "Payday Loan"
      elsif line =~ /CHECKCARD \d{4}\s+(.+?)(?=\s{2,}|x{3,}|\s+\S+\s+[A-Z]{2}\b)/i
        Regexp.last_match(1).strip
      elsif line =~ /^(.+?)(?=\s+\d{2}\/\d{2}|\s+#)/
        Regexp.last_match(1).strip.gsub(/\s+POS$/i, "").strip
      else
        line[0..25].strip
      end
    end
end
