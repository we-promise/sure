require "test_helper"

class Provider::BrexTest < ActiveSupport::TestCase
  def setup
    @provider = Provider::Brex.new("test_token", base_url: "https://api-staging.brex.com")
  end

  test "initializes with token and default base_url" do
    provider = Provider::Brex.new("my_token")
    assert_equal "my_token", provider.token
    assert_equal "https://api.brex.com", provider.base_url
  end

  test "initializes with custom base_url" do
    assert_equal "test_token", @provider.token
    assert_equal "https://api-staging.brex.com", @provider.base_url
  end

  test "initializes with stripped token and removes trailing base url slash" do
    provider = Provider::Brex.new(" test_token \n", base_url: "https://api.brex.com/")

    assert_equal "test_token", provider.token
    assert_equal "https://api.brex.com", provider.base_url
  end

  test "initializes with official staging base url" do
    provider = Provider::Brex.new("test_token", base_url: "https://api-staging.brex.com/")

    assert_equal "https://api-staging.brex.com", provider.base_url
  end

  test "rejects arbitrary base urls" do
    [
      "http://api.brex.com",
      "https://evil.example.test",
      "https://localhost",
      "https://127.0.0.1",
      "https://10.0.0.1",
      "https://api.brex.com.evil.example",
      "https://api.brex.com@127.0.0.1",
      "https://api.brex.com:444",
      "https://api.brex.com/v1",
      "https://api.brex.com?host=evil.example.test",
      "//api.brex.com"
    ].each do |base_url|
      assert_raises ArgumentError do
        Provider::Brex.new("test_token", base_url: base_url)
      end
    end
  end

  test "BrexError includes error_type" do
    error = Provider::Brex::BrexError.new("Test error", :unauthorized)
    assert_equal "Test error", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "BrexError defaults error_type to unknown" do
    error = Provider::Brex::BrexError.new("Test error")
    assert_equal :unknown, error.error_type
  end

  test "fetches cash accounts from the v2 endpoint with bearer auth" do
    response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "cash_1", name: "Operating" } ] }.to_json,
      headers: {}
    )

    Provider::Brex.expects(:get)
      .with(
        "https://api.brex.com/v2/accounts/cash?limit=1000",
        headers: {
          "Authorization" => "Bearer test_token",
          "Content-Type" => "application/json",
          "Accept" => "application/json"
        }
      )
      .returns(response)

    accounts = Provider::Brex.new(" test_token ").get_cash_accounts

    assert_equal 1, accounts.length
    assert_equal "cash_1", accounts.first[:id]
    assert_equal "cash", accounts.first[:account_kind]
  end

  test "fetches card accounts from the paginated v2 endpoint" do
    response = OpenStruct.new(
      code: 200,
      body: [ { id: "card_account_1", status: "ACTIVE" } ].to_json,
      headers: {}
    )

    Provider::Brex.expects(:get)
      .with(
        "https://api.brex.com/v2/accounts/card?limit=1000",
        headers: {
          "Authorization" => "Bearer test_token",
          "Content-Type" => "application/json",
          "Accept" => "application/json"
        }
      )
      .returns(response)

    accounts = Provider::Brex.new("test_token").get_card_accounts

    assert_equal 1, accounts.length
    assert_equal "card_account_1", accounts.first[:id]
    assert_equal "card", accounts.first[:account_kind]
  end

  test "aggregates card accounts into one provider account" do
    cash_response = OpenStruct.new(
      code: 200,
      body: { items: [] }.to_json,
      headers: {}
    )
    card_response = OpenStruct.new(
      code: 200,
      body: {
        items: [
          {
            id: "card_account_1",
            status: "ACTIVE",
            current_balance: { amount: 12_345, currency: "USD" },
            available_balance: { amount: 100_000, currency: "USD" },
            account_limit: { amount: 250_000, currency: "USD" }
          }
        ]
      }.to_json,
      headers: {}
    )

    Provider::Brex.stubs(:get).returns(cash_response, card_response)

    accounts_data = Provider::Brex.new("test_token").get_accounts

    assert_equal [ "card_primary" ], accounts_data[:accounts].map { |account| account[:id] }
    assert_equal "card", accounts_data[:accounts].first[:account_kind]
    assert_equal 1, accounts_data[:accounts].first[:card_accounts_count]
  end

  test "does not aggregate mixed currency card balances" do
    cash_response = OpenStruct.new(
      code: 200,
      body: { items: [] }.to_json,
      headers: {}
    )
    card_response = OpenStruct.new(
      code: 200,
      body: [
        {
          id: "card_account_1",
          current_balance: { amount: 12_345, currency: "USD" }
        },
        {
          id: "card_account_2",
          current_balance: { amount: 6_789, currency: "EUR" }
        }
      ].to_json,
      headers: {}
    )

    Provider::Brex.stubs(:get).returns(cash_response, card_response)

    accounts_data = Provider::Brex.new("test_token").get_accounts

    assert_nil accounts_data[:accounts].first[:current_balance]
  end

  test "guards repeated pagination cursors" do
    first_response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "tx_1" } ], next_cursor: "cursor_1" }.to_json,
      headers: {}
    )
    second_response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "tx_2" } ], next_cursor: "cursor_1" }.to_json,
      headers: {}
    )

    Provider::Brex.stubs(:get).returns(first_response, second_response)

    error = assert_raises Provider::Brex::BrexError do
      Provider::Brex.new("test_token").get_primary_card_transactions
    end

    assert_equal :pagination_error, error.error_type
  end

  test "guards pagination page cap" do
    responses = (1..26).map do |page|
      OpenStruct.new(
        code: 200,
        body: { items: [ { id: "tx_#{page}" } ], next_cursor: "cursor_#{page}" }.to_json,
        headers: {}
      )
    end

    Provider::Brex.stubs(:get).returns(*responses)

    error = assert_raises Provider::Brex::BrexError do
      Provider::Brex.new("test_token").get_primary_card_transactions
    end

    assert_equal :pagination_error, error.error_type
    assert_includes error.message, "exceeded 25 pages"
  end

  test "sends posted_at_start as RFC3339 date time" do
    response = OpenStruct.new(
      code: 200,
      body: { items: [] }.to_json,
      headers: {}
    )

    Provider::Brex.expects(:get)
      .with(
        "https://api.brex.com/v2/transactions/card/primary?posted_at_start=2026-01-02T00%3A00%3A00Z&limit=1000",
        headers: {
          "Authorization" => "Bearer test_token",
          "Content-Type" => "application/json",
          "Accept" => "application/json"
        }
      )
      .returns(response)

    Provider::Brex.new("test_token").get_primary_card_transactions(start_date: Date.new(2026, 1, 2))
  end

  test "raises clear error for invalid start date" do
    error = assert_raises ArgumentError do
      Provider::Brex.new("test_token").get_primary_card_transactions(start_date: "not-a-date")
    end

    assert_includes error.message, "Invalid start_date"
  end

  test "maps rate limits and exposes trace id without leaking body" do
    response = OpenStruct.new(
      code: 429,
      body: { message: "secret raw provider body" }.to_json,
      headers: { "x-brex-trace-id" => "trace_123" }
    )

    Provider::Brex.stubs(:get).returns(response)

    error = assert_raises Provider::Brex::BrexError do
      Provider::Brex.new("test_token").get_cash_accounts
    end

    assert_equal :rate_limited, error.error_type
    assert_equal 429, error.http_status
    assert_equal "trace_123", error.trace_id
    refute_includes error.message, "secret raw provider body"
  end

  test "maps non-success responses without exposing provider body" do
    expectations = {
      400 => [ :bad_request, "Bad request to Brex API" ],
      401 => [ :unauthorized, "Invalid Brex API token or account permissions" ],
      403 => [ :access_forbidden, "Access forbidden - check Brex API token scopes" ],
      404 => [ :not_found, "Brex resource not found" ],
      500 => [ :fetch_failed, "Failed to fetch data from Brex API: HTTP 500" ]
    }

    expectations.each do |status, (error_type, message)|
      response = OpenStruct.new(
        code: status,
        body: { message: "secret provider body #{status}" }.to_json,
        headers: { "X-Brex-Trace-Id" => "trace_#{status}" }
      )

      Provider::Brex.stubs(:get).returns(response)

      error = assert_raises Provider::Brex::BrexError do
        Provider::Brex.new("test_token").get_cash_accounts
      end

      assert_equal error_type, error.error_type
      assert_equal status, error.http_status
      assert_equal "trace_#{status}", error.trace_id
      assert_equal message, error.message
      refute_includes error.message, "secret provider body"
    end
  end
end
