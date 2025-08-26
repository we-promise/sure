require "httparty"
require "openssl"

module BankProviders
  class Mercury < Base
    include HTTParty
    base_uri "https://api.mercury.com/api/v1"

    def initialize(api_key: ENV["MERCURY_API_KEY"], api_secret: ENV["MERCURY_API_SECRET"])
      @api_key = api_key
      @api_secret = api_secret
    end

    def list_accounts
      request(:get, "/accounts")
    end

    def fetch_transactions(account_id, from: nil, to: nil)
      params = {}
      params[:start] = from if from
      params[:end] = to if to
      request(:get, "/accounts/#{account_id}/transactions", query: params)
    end

    private
      attr_reader :api_key, :api_secret

      def request(method, path, query: nil, body: nil)
        headers = signed_headers(method.to_s.upcase, path, body)
        options = { headers: headers }
        options[:query] = query if query && !query.empty?
        options[:body] = body.to_json if body

        response = self.class.send(method, path, options)
        JSON.parse(response.body)
      end

      def signed_headers(method, path, body)
        timestamp = Time.now.utc.to_i.to_s
        payload = "#{timestamp}#{method}#{path}#{body ? body.to_json : ""}"
        signature = OpenSSL::HMAC.hexdigest("SHA256", api_secret, payload)

        {
          "X-Mercury-Api-Key" => api_key,
          "X-Mercury-Timestamp" => timestamp,
          "X-Mercury-Signature" => signature,
          "Content-Type" => "application/json"
        }
      end
  end
end

BankProviders::Registry.register(:mercury, BankProviders::Mercury)
