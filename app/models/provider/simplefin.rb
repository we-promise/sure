class Provider::Simplefin
  include HTTParty

  headers "User-Agent" => "Maybe Finance SimpleFin Client"

  def initialize
    self.class.default_options.merge!(verify: true, ssl_verify_mode: :peer)
  end

  def claim_access_url(setup_token)
    # Decode the base64 setup token to get the claim URL
    claim_url = Base64.decode64(setup_token)

    response = HTTParty.post(claim_url, {
      headers: {
        "User-Agent" => "Maybe Finance SimpleFin Client"
      },
      verify: true,
      ssl_verify_mode: :peer
    })

    case response.code
    when 200
      # The response body contains the access URL with embedded credentials
      response.body.strip
    when 403
      raise SimplefinError.new("Setup token may be compromised, expired, or already used", :token_compromised)
    else
      raise SimplefinError.new("Failed to claim access URL: #{response.code} #{response.message}", :claim_failed)
    end
  end

  def get_accounts(access_url, start_date: nil, end_date: nil, pending: nil)
    # Build query parameters
    query_params = {}
    query_params["start-date"] = start_date.strftime("%Y-%m-%d") if start_date
    query_params["end-date"] = end_date.strftime("%Y-%m-%d") if end_date
    query_params["pending"] = pending ? "1" : "0" unless pending.nil?

    accounts_url = "#{access_url}/accounts"
    accounts_url += "?#{URI.encode_www_form(query_params)}" unless query_params.empty?

    # The access URL already contains HTTP Basic Auth credentials
    response = HTTParty.get(accounts_url, {
      headers: {
        "User-Agent" => "Maybe Finance SimpleFin Client"
      },
      verify: true,
      ssl_verify_mode: :peer
    })

    case response.code
    when 200
      JSON.parse(response.body, symbolize_names: true)
    when 403
      raise SimplefinError.new("Access URL is no longer valid", :access_forbidden)
    when 402
      raise SimplefinError.new("Payment required to access this account", :payment_required)
    else
      raise SimplefinError.new("Failed to fetch accounts: #{response.code} #{response.message}", :fetch_failed)
    end
  end

  def get_info(base_url)
    response = HTTParty.get("#{base_url}/info", {
      headers: {
        "User-Agent" => "Maybe Finance SimpleFin Client"
      },
      verify: true,
      ssl_verify_mode: :peer
    })

    case response.code
    when 200
      response.body.strip.split("\n")
    else
      raise SimplefinError.new("Failed to get server info: #{response.code} #{response.message}", :info_failed)
    end
  end

  class SimplefinError < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end
end
