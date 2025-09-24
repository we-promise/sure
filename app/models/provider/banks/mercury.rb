require 'openssl'
require 'base64'
require 'cgi'

class Provider::Banks::Mercury < Provider::Banks::Base
  # NOTE: This is a skeleton adapter. Wire real endpoints per Mercury API docs.
  class Mapper < Provider::Banks::Mapper
    def normalize_account(payload)
      data = payload.with_indifferent_access
      {
        provider_account_id: data[:id].to_s,
        name: data[:name] || "Mercury Account",
        currency: data[:currency] || "USD",
        current_balance: to_decimal(data[:current_balance] || data.dig(:balances, :current)),
        available_balance: to_decimal(data[:available_balance] || data.dig(:balances, :available))
      }
    end

    def normalize_transaction(payload, currency:)
      data = payload.with_indifferent_access
      amount = to_decimal(data[:amount] || data.dig(:amount, :value))
      # Internal convention: expense positive. If `direction` provided, debit => positive, credit => negative.
      # If no direction is provided by the API, preserve the sign returned by Mercury.
      amount_signed = if data.key?(:direction)
        data[:direction] == "debit" ? amount : -amount
      else
        amount
      end

      {
        external_id: "mercury_#{data[:id] || data[:uuid]}",
        posted_at: parse_date(data[:postedAt] || data[:date] || data[:posted_at]).to_date,
        amount: amount_signed,
        description: data[:bankDescription] || data[:description] || data[:note] || data[:externalMemo] || data.dig(:merchant, :name) || "Mercury transaction"
      }
    end

    private
      def to_decimal(val)
        BigDecimal(val.to_s)
      rescue
        BigDecimal("0")
      end

      def parse_date(val)
        case val
        when String then DateTime.parse(val)
        when Integer, Float then Time.at(val)
        when Time, DateTime, Date then val
        else Time.current
        end
      end
  end

  def verify_credentials!
    # Minimal call to assert auth works
    list_accounts
    true
  end

  def list_accounts
    # Per Mercury docs: GET /api/v1/accounts returns a JSON object with `accounts: [...]`
    extract_items(client.get('/api/v1/accounts'), preferred_keys: %i[accounts data])
  end

  def list_transactions(account_id:, start_date:, end_date:)
    # Per Mercury docs: GET /api/v1/account/:id/transactions
    # Pagination is limit/offset (with optional order). Date range filtering is not documented.
    path = "/api/v1/account/#{account_id}/transactions"
    limit = 500
    offset = 0
    results = []
    100.times do
      res = client.get(path, query: { limit: limit, offset: offset, order: 'desc' })
      items = extract_items(res, preferred_keys: %i[transactions data])
      results.concat(Array(items))
      break if Array(items).length < limit
      offset += limit
    end
    results
  end

  # Optional webhook verifier stub. Adjust per Mercury docs.
  def verify_webhook_signature!(raw_body, headers)
    # Example: HMAC SHA256 with signing secret and delivered signature header
    secret = @credentials[:webhook_signing_secret]
    return true unless secret.present? # If not configured, skip verification for now
    signature = headers['X-Mercury-Signature'] || headers['HTTP_X_MERCURY_SIGNATURE']
    timestamp = headers['X-Mercury-Timestamp'] || headers['HTTP_X_MERCURY_TIMESTAMP']
    return false unless signature.present? && timestamp.present?

    # Reject replayed/old signatures (5 minutes leeway)
    begin
      ts = Time.at(timestamp.to_i)
      return false if (Time.now.utc - ts) > 300
    rescue
      return false
    end

    data = "#{timestamp}.#{raw_body}"
    digest = OpenSSL::Digest.new('sha256')
    hmac_bin = OpenSSL::HMAC.digest(digest, secret, data)
    expected_hex = hmac_bin.unpack1('H*')
    expected_b64 = Base64.strict_encode64(hmac_bin)

    ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected_hex) ||
      ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected_b64)
  end

  private
    def client
      @client ||= Provider::Banks::HttpClient.new(
        base_url: ENV.fetch('MERCURY_API_BASE_URL', 'https://api.mercury.com'),
        auth: Provider::Banks::AuthStrategy::BearerToken.new(@credentials[:api_key]),
        headers: { 'User-Agent' => 'Sure Finance Mercury Client' }
      )
    end

    def extract_items(res, preferred_keys: [])
      case res
      when Array
        res
      when Hash
        preferred_keys.each do |k|
          return res[k] if res[k].is_a?(Array)
        end
        res.values.find { |v| v.is_a?(Array) } || []
      else
        []
      end
    end
    
end
