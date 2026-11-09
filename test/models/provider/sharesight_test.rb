require "test_helper"

class Provider::SharesightTest < ActiveSupport::TestCase
  API = Provider::Sharesight::BASE_URI
  PORTFOLIOS_URL = "#{API}/api/v2/portfolios.json".freeze

  setup do
    @provider = Provider::Sharesight.new(client_id: " client-id ", client_secret: "client-secret")
  end

  test "exchanges the client credentials for a token and reuses it" do
    token = stub_request(:post, "#{API}/oauth2/token")
      .with(body: { grant_type: "client_credentials", client_id: "client-id", client_secret: "client-secret" })
      .to_return(json_response(access_token: "token-1", expires_in: 1800))
    portfolios = stub_request(:get, PORTFOLIOS_URL)
      .with(headers: { "Authorization" => "Bearer token-1" })
      .to_return(json_response(portfolios: [ { id: 42, name: "Shares", currency_code: "AUD" } ]))

    assert_equal [ { "id" => 42, "name" => "Shares", "currency_code" => "AUD" } ], @provider.fetch_portfolios
    @provider.fetch_portfolios

    assert_requested token, times: 1
    assert_requested portfolios, times: 2
  end

  test "asks for a new token once when the current one has expired" do
    stub_request(:post, "#{API}/oauth2/token")
      .to_return(json_response(access_token: "stale"), json_response(access_token: "fresh"))
    stub_request(:get, PORTFOLIOS_URL).with(headers: { "Authorization" => "Bearer stale" }).to_return(status: 401)
    stub_request(:get, PORTFOLIOS_URL).with(headers: { "Authorization" => "Bearer fresh" }).to_return(json_response(portfolios: []))

    assert_equal [], @provider.fetch_portfolios
  end

  test "rejected client credentials raise an authentication error" do
    stub_request(:post, "#{API}/oauth2/token").to_return(status: 401, body: "invalid_client")

    error = assert_raises(Provider::Sharesight::AuthenticationError) { @provider.fetch_portfolios }
    assert_match "client ID and secret", error.message
  end

  test "an account without API access raises an authentication error" do
    stub_token
    stub_request(:get, PORTFOLIOS_URL).to_return(status: 403)

    assert_raises(Provider::Sharesight::AuthenticationError) { @provider.fetch_portfolios }
  end

  test "rate limiting raises a rate limit error" do
    stub_token
    stub_request(:get, PORTFOLIOS_URL).to_return(status: 429)

    assert_raises(Provider::Sharesight::RateLimitError) { @provider.fetch_portfolios }
  end

  test "fetches a portfolio's report, trades, payouts and cash account transactions" do
    stub_token
    stub_request(:get, "#{API}/api/v3/portfolios/42/performance")
      .with(query: { include_sales: "true" })
      .to_return(json_response(report: { value: 100.0, holdings: [] }))
    stub_request(:get, "#{API}/api/v2/portfolios/42/trades.json").to_return(json_response(trades: [ { id: 1 } ]))
    stub_request(:get, "#{API}/api/v2/portfolios/42/payouts.json")
      .with(query: { start_date: "2021-02-03", end_date: "2026-10-23" })
      .to_return(json_response(payouts: [ { id: 2 } ]))
    stub_request(:get, "#{API}/api/v2/cash_accounts.json").to_return(json_response(cash_accounts: [ { id: 7 } ]))
    stub_request(:get, "#{API}/api/v2/cash_accounts/7/cash_account_transactions.json")
      .to_return(json_response(cash_account_transactions: [ { id: 3 } ]))

    assert_equal({ "value" => 100.0, "holdings" => [] }, @provider.fetch_performance("42"))
    assert_equal [ { "id" => 1 } ], @provider.fetch_trades("42")
    assert_equal [ { "id" => 2 } ], @provider.fetch_payouts("42", start_date: Date.new(2021, 2, 3), end_date: Date.new(2026, 10, 23))
    assert_equal [ { "id" => 7 } ], @provider.fetch_cash_accounts
    assert_equal [ { "id" => 3 } ], @provider.fetch_cash_account_transactions(7)
  end

  test "a response that isn't JSON raises an API error" do
    stub_token
    stub_request(:get, PORTFOLIOS_URL).to_return(status: 200, body: "<html>maintenance</html>", headers: { "Content-Type" => "text/html" })

    assert_raises(Provider::Sharesight::ApiError) { @provider.fetch_portfolios }
  end

  test "requires a client id and secret" do
    assert_raises(Provider::Sharesight::ConfigurationError) { Provider::Sharesight.new(client_id: "", client_secret: "secret") }
    assert_raises(Provider::Sharesight::ConfigurationError) { Provider::Sharesight.new(client_id: "id", client_secret: nil) }
  end

  private

    def stub_token
      stub_request(:post, "#{API}/oauth2/token").to_return(json_response(access_token: "token"))
    end

    def json_response(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
