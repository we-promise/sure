require "httparty"

module BankProviders
  class Wise < Base
    include HTTParty
    base_uri "https://api.transferwise.com/v1"

    def initialize(api_token: ENV["WISE_API_TOKEN"])
      @api_token = api_token
    end

    def list_accounts
      request(:get, "/profiles")
    end

    def fetch_transactions(account_id, from: nil, to: nil)
      params = {}
      params[:from] = from if from
      params[:to] = to if to
      request(:get, "/accounts/#{account_id}/statement", query: params)
    end

    private
      attr_reader :api_token

      def request(method, path, query: nil, body: nil)
        headers = {
          "Authorization" => "Bearer #{api_token}",
          "Content-Type" => "application/json"
        }
        options = { headers: headers }
        options[:query] = query if query && !query.empty?
        options[:body] = body.to_json if body

        response = self.class.send(method, path, options)
        JSON.parse(response.body)
      end
  end
end

BankProviders::Registry.register(:wise, BankProviders::Wise)
