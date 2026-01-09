class Provider::Sophtron
  include HTTParty

  headers "User-Agent" => "Sure Finance So Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  attr_reader :user_id, :access_key, :base_url

  def initialize(user_id, access_key, base_url: "https://api.sophtron.com/api/v2")
    @user_id = user_id
    @access_key = access_key
    @base_url = base_url
  end

  # Get all accounts
  # Returns: { accounts: [...], total: N }
  def get_accounts
    # fetching accounts for sophtron
    # Obtain customer IDs using a dedicated helper
    customer_ids = get_customer_ids
    all_accounts = []
    customer_ids.each do |cust_id|
      begin
        accounts_resp = get_customer_accounts(cust_id)
        # `handle_response` returns parsed JSON (hash/array) so normalize
        raw_accounts = if accounts_resp.is_a?(Hash) && accounts_resp[:accounts].is_a?(Array)
          accounts_resp[:accounts]
        elsif accounts_resp.is_a?(Array)
          accounts_resp
        else
          []
        end
        normalized = raw_accounts.map { |a| a.transform_keys { |k| k.to_s.underscore }.with_indifferent_access }

        # Ensure each account payload includes the originating customer id
        normalized.each do |acc|
          begin
            # check common variants that may already exist
            existing = acc[:customer_id]
            acc[:customer_id] = cust_id.to_s if existing.blank?
          rescue => _e
          end
        end

        # per-account logging removed
        all_accounts.concat(normalized)
      rescue SophtronError => e
        Rails.logger.warn("Failed to fetch accounts for customer #{cust_id}: #{e.message}")
      rescue => e
        Rails.logger.warn("Unexpected error fetching accounts for customer #{cust_id}: #{e.class} #{e.message}")
      end
    end

    # Deduplicate by id where present
    unique_accounts = all_accounts.uniq { |a| a[:id].to_s }
    { accounts: unique_accounts, total: unique_accounts.length, customer_ids: customer_ids }
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Sophtron API: GET /accounts failed: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Sophtron API: Unexpected error during GET /accounts: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get transactions for a specific account
  # Returns: { transactions: [...], total: N }
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description }
  def get_account_transactions(customer_id, account_id, start_date: nil, end_date: nil)
    query_params = {}

    if start_date
      query_params[:startDate] = start_date.to_date
    end
    if end_date
      query_params[:endDate] = end_date.to_date
    else
      query_params[:endDate] = Date.tomorrow
    end

    path = "/customers/#{ERB::Util.url_encode(customer_id.to_s)}/accounts/#{ERB::Util.url_encode(account_id.to_s)}/transactions"
    path += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?
    url = "#{@base_url}#{path}"

    response = self.class.get(
      url,
      headers: auth_headers(url: url, http_method: "GET")
    )
    parsed = handle_response(response)

    # Normalize transactions response into { transactions: [...], total: N }
    if parsed.is_a?(Array)
      txs = parsed.map { |tx| tx.transform_keys { |k| k.to_s.underscore }.with_indifferent_access }
      mapped = txs.map { |tx| map_transaction(tx, account_id) }
      { transactions: mapped, total: mapped.length }
    elsif parsed.is_a?(Hash)
      if parsed[:transactions].is_a?(Array)
        txs = parsed[:transactions].map { |tx| tx.transform_keys { |k| k.to_s.underscore }.with_indifferent_access }
        mapped = txs.map { |tx| map_transaction(tx, account_id) }
        parsed[:transactions] = mapped
        parsed[:total] = parsed[:total] || mapped.length
        parsed
      else
        # Single transaction object -> wrap and map
        single = parsed.transform_keys { |k| k.to_s.underscore }.with_indifferent_access
        mapped = map_transaction(single, account_id)
        { transactions: [ mapped ], total: 1 }
      end
    else
      { transactions: [], total: 0 }
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Sophtron API: GET #{path} failed: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Sophtron API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Get balance for a specific account
  # Returns: { balance: { amount: N, currency: "USD" } }
  def get_account_balance(customer_id, account_id)
    path = "/customers/#{ERB::Util.url_encode(customer_id.to_s)}/accounts/#{ERB::Util.url_encode(account_id.to_s)}"
    url = "#{@base_url}#{path}"

    response = self.class.get(
      url,
      headers: auth_headers(url: url, http_method: "GET")
    )

    parsed = handle_response(response)

    # Normalize balance information into { balance: { amount: N, currency: "XXX" } }
    if parsed.is_a?(Hash)
      # Prefer explicit :balance object
      if parsed[:balance].is_a?(Hash)
        bal = parsed[:balance].transform_keys { |k| k.to_s.underscore }.with_indifferent_access
        return { balance: { amount: bal[:amount], currency: bal[:currency] } }
      end
    end

    # Fallback: return whatever the parsed payload was (keeps original behavior)
    parsed
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Sophtron API: GET #{path} failed: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Sophtron API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
    raise SophtronError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  private

    def sophtron_auth_code(url:, http_method:)
      require "base64"
      require "openssl"
      # sophtron auth code generation
      # Parse path portion of the URL and use the last "/..." segment (matching upstream examples)
      uri = URI.parse(url)
      # Sign the last path segment (lowercased) and include the query string if present
      path = (uri.path || "").downcase
      idx = path.rindex("/")
      last_seg = idx ? path[idx..-1] : path
      query_str = uri.query ? "?#{uri.query.to_s.downcase}" : ""
      auth_path = "#{last_seg}#{query_str}"
      # Build the plain text to sign: "METHOD\n/auth_path"
      plain_key = "#{http_method.to_s.upcase}\n#{auth_path}"
      # Decode the base64 access key and compute HMAC-SHA256
      begin
        key_bytes = Base64.decode64(@access_key.to_s)
      rescue => decode_err
        Rails.logger.error("[sophtron_auth_code] Failed to decode access_key: #{decode_err.class}: #{decode_err.message}")
        raise
      end
      signature = OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), key_bytes, plain_key)
      sig_b64_str = Base64.strict_encode64(signature)
      auth_code = "FIApiAUTH:#{@user_id}:#{sig_b64_str}:#{auth_path}"
      auth_code
    end

    def auth_headers(url:, http_method:)
      {
        "Authorization" => sophtron_auth_code(url: url, http_method: http_method),
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    # Fetch list of customer IDs by calling GET /customers and extracting identifier fields
    def get_customer_ids
      url = "#{@base_url}/customers"
      response = self.class.get(
        url,
        headers: auth_headers(url: url, http_method: "GET")
      )
      parsed = handle_response(response)
      ids = []
      if parsed.is_a?(Array)
        ids = parsed.map do |r|
          next unless r.is_a?(Hash)
          # Find a key that likely contains the customer id (handles :CustomerID, :customerID, :customer_id, :ID, :id)
          key = r.keys.find { |k| k.to_s.downcase.include?("customer") && k.to_s.downcase.include?("id") } ||
                r.keys.find { |k| k.to_s.downcase == "id" }
          r[key]
        end.compact
      elsif parsed.is_a?(Hash)
        if parsed[:customers].is_a?(Array)
          ids = parsed[:customers].map do |r|
            next unless r.is_a?(Hash)
            key = r.keys.find { |k| k.to_s.downcase.include?("customer") && k.to_s.downcase.include?("id") } ||
                  r.keys.find { |k| k.to_s.downcase == "id" }
            r[key]
          end.compact
        else
          key = parsed.keys.find { |k| k.to_s.downcase.include?("customer") && k.to_s.downcase.include?("id") } ||
                parsed.keys.find { |k| k.to_s.downcase == "id" }
          ids = [ parsed[key] ].compact
        end
      end

      # Normalize to strings and unique (avoid destructive methods that may return nil)
      ids = ids.map(&:to_s).compact.uniq
      ids
    end

    # Fetch accounts for a specific customer via GET /customers/:customer_id/accounts
    def get_customer_accounts(customer_id)
      path = "/customers/#{ERB::Util.url_encode(customer_id.to_s)}/accounts"
      url = "#{@base_url}#{path}"
      response = self.class.get(
        url,
        headers: auth_headers(url: url, http_method: "GET")
      )
      handle_response(response)
    end

    # Map a normalized Sophtron transaction hash into our standard transaction shape
    # Returns: { id, accountId, type, status, amount, currency, date, merchant, description }
    def map_transaction(tx, account_id)
      tx = tx.with_indifferent_access
      {
        id: tx[:transaction_id],
        accountId: account_id,
        type: tx[:type] || "unknown",
        status: tx[:status] || "completed",
        amount: tx[:amount] || 0.0,
        currency: tx[:currency] || "USD",
        date: tx[:transaction_date] || nil,
        merchant: tx[:merchant] || extract_merchant(tx[:description]) ||"",
        description: tx[:description] || ""
      }.with_indifferent_access
    end

    def extract_merchant(line)
      line = line.strip
      return nil if line.empty?

      # 1. Handle special bank fees and automated transactions
      if line =~ /INSUFFICIENT FUNDS FEE/i
        return "Bank Fee: Insufficient Funds"
      elsif line =~ /OVERDRAFT PROTECTION/i
        return "Bank Transfer: Overdraft Protection"
      elsif line =~ /AUTO PAY WF HOME MTG/i
        return "Wells Fargo Home Mortgage"
      elsif line =~ /PAYDAY LOAN/i
        return "Payday Loan"
      end

      # 2. Refined CHECKCARD Pattern
      # Logic:
      # - Start after 'CHECKCARD XXXX '
      # - Capture everything (.+?)
      # - STOP when we see:
      #   a) Two or more spaces (\s{2,})
      #   b) A masked number (x{3,})
      #   c) A pattern of [One Word] + [Space] + [State Code] (\s+\S+\s+[A-Z]{2}\b)
      #      The (\s+\S+) part matches the city, so we stop BEFORE it.
      if line =~ /CHECKCARD \d{4}\s+(.+?)(?=\s{2,}|x{3,}|\s+\S+\s+[A-Z]{2}\b)/i
        return $1.strip
      end

      # 3. Handle standard purchase rows (e.g., EXXONMOBIL POS 12/08)
      # Stops before date (MM/DD) or hash (#)
      if line =~ /^(.+?)(?=\s+\d{2}\/\d{2}|\s+#)/
        name = $1.strip
        return name.gsub(/\s+POS$/i, "").strip
      end

      # 4. Fallback for other formats
      line[0..25].strip
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Sophtron API: Bad request - #{response.body}"
        raise SophtronError.new("Bad request to Sophtron API: #{response.body}", :bad_request)
      when 401
        raise SophtronError.new("Invalid User ID or Access key", :unauthorized)
      when 403
        raise
        SophtronError.new("Access forbidden - check your User ID and Access key permissions", :access_forbidden)
      when 404
        raise SophtronError.new("Resource not found", :not_found)
      when 429
        raise SophtronError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        Rails.logger.error "Sophtron API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise SophtronError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    class SophtronError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
