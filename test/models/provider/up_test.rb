require "test_helper"

class Provider::UpTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  test "fetches paginated account transactions following JSON:API links.next with bearer auth" do
    next_url = "https://api.up.com.au/api/v1/accounts/acc_123/transactions?page%5Bafter%5D=cursor2"
    responses = [
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          data: [ { type: "transactions", id: "tx_1", attributes: { status: "SETTLED" }, relationships: { account: { data: { id: "acc_123" } } } } ],
          links: { prev: nil, next: next_url }
        }.to_json
      ),
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: {
          data: [ { type: "transactions", id: "tx_2", attributes: { status: "HELD" }, relationships: { account: { data: { id: "acc_123" } } } } ],
          links: { prev: nil, next: nil }
        }.to_json
      )
    ]
    requests = []

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      responses.shift
    }) do
      client = Provider::Up.new("up-access-token")

      transactions = client.get_account_transactions(
        account_id: "acc_123",
        since: Date.new(2026, 1, 1)
      )

      assert_equal [ "tx_1", "tx_2" ], transactions.map { |tx| tx[:id] }
      assert_equal [ "acc_123", "acc_123" ], transactions.map { |tx| tx[:account_id] }
      assert_equal "SETTLED", transactions.first[:status]
    end

    assert_equal 2, requests.size
    assert_match "/accounts/acc_123/transactions", requests.first[:url]
    assert_equal "Bearer up-access-token", requests.first[:headers]["Authorization"]
    assert_match "2026-01-01", requests.first[:query]["filter[since]"]
    assert_equal 100, requests.first[:query]["page[size]"]
    # Pagination follows the absolute next URL with no extra query params.
    assert_equal next_url, requests.second[:url]
    assert_nil requests.second[:query]
  end

  test "flattens JSON:API account resources" do
    response = FakeResponse.new(
      code: 200,
      message: "OK",
      body: {
        data: [ {
          type: "accounts",
          id: "acc_123",
          attributes: {
            displayName: "Spending",
            accountType: "TRANSACTIONAL",
            ownershipType: "INDIVIDUAL",
            balance: { currencyCode: "AUD", value: "123.45", valueInBaseUnits: 12345 }
          }
        } ],
        links: { prev: nil, next: nil }
      }.to_json
    )

    Provider::Up.stub(:get, ->(_url, headers:, query: nil) { response }) do
      accounts = Provider::Up.new("up-access-token").get_accounts

      assert_equal 1, accounts.size
      account = accounts.first
      assert_equal "acc_123", account[:id]
      assert_equal "Spending", account[:displayName]
      assert_equal "TRANSACTIONAL", account[:accountType]
      assert_equal "AUD", account.dig(:balance, :currencyCode)
      assert_equal "123.45", account.dig(:balance, :value)
    end
  end

  test "raises typed errors for unauthorized responses" do
    response = FakeResponse.new(code: 401, message: "Unauthorized", body: "{}")

    Provider::Up.stub(:get, ->(_url, headers:, query: nil) { response }) do
      error = assert_raises Provider::Up::UpError do
        Provider::Up.new("invalid-token").get_accounts
      end

      assert_equal :unauthorized, error.error_type
    end
  end

  test "raises configuration error when token blank" do
    error = assert_raises Provider::Up::UpError do
      Provider::Up.new("")
    end

    assert_equal :configuration_error, error.error_type
  end
end
