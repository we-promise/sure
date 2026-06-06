require "test_helper"

class Provider::AkahuTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  test "fetches paginated account transactions with Akahu auth headers" do
    responses = [
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: { items: [ { _id: "tx_1" } ], cursor: { next: "next-cursor" } }.to_json
      ),
      FakeResponse.new(
        code: 200,
        message: "OK",
        body: { items: [ { _id: "tx_2" } ] }.to_json
      )
    ]
    requests = []

    Provider::Akahu.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      responses.shift
    }) do
      client = Provider::Akahu.new(app_token: "akahu-app-credential", user_token: "akahu-user-credential")

      transactions = client.get_account_transactions(
        account_id: "acc_123",
        start_date: Date.new(2026, 1, 1)
      )

      assert_equal [ "tx_1", "tx_2" ], transactions.map { |tx| tx[:_id] }
    end

    assert_equal 2, requests.size
    assert_match "/accounts/acc_123/transactions", requests.first[:url]
    assert_equal "Bearer akahu-user-credential", requests.first[:headers]["Authorization"]
    assert_equal "akahu-app-credential", requests.first[:headers]["X-Akahu-Id"]
    assert_match "2026-01-01", requests.first[:query][:start]
    assert_equal "next-cursor", requests.second[:query][:cursor]
  end

  test "raises typed errors for unauthorized responses" do
    response = FakeResponse.new(code: 401, message: "Unauthorized", body: "{}")

    Provider::Akahu.stub(:get, ->(_url, headers:, query: nil) { response }) do
      error = assert_raises Provider::Akahu::AkahuError do
        Provider::Akahu.new(app_token: "akahu-app-credential", user_token: "invalid-credential").get_accounts
      end

      assert_equal :unauthorized, error.error_type
    end
  end
end
