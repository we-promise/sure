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

  test "canonical pages decode monetary JSON numbers exactly and read only one page" do
    response = FakeResponse.new(code: 200, message: "OK",
      body: '{"items":[{"_id":"tx_1","amount":-0.123456789012345678}],"cursor":{"next":"next-page"}}')
    requests = []
    Provider::Akahu.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, query: query, headers: headers }
      response
    }) do
      page = Provider::Akahu.new(app_token: "app", user_token: "user").get_account_transactions_page(
        account_id: "acc/1", start_date: "2026-01-01T00:00:00Z", cursor: "current-page"
      )

      assert_instance_of BigDecimal, page[:items].first[:amount]
      assert_equal BigDecimal("-0.123456789012345678"), page[:items].first[:amount]
      assert_equal "next-page", page[:next_cursor]
      assert_equal page[:items], page[:evidence][:items]
    end
    assert_equal 1, requests.size
    assert_includes requests.first[:url], "acc%2F1"
    assert_equal "current-page", requests.first[:query][:cursor]
    assert_equal "2026-01-01T00:00:00.000Z", requests.first[:query][:start]
    assert_equal "app", requests.first[:headers]["X-Akahu-Id"]
  end

  test "canonical pending pages do not treat missing or failed payloads as empty success" do
    [ {}, { items: nil }, { items: [], success: false }, { items: [], cursor: { next: false } } ].each do |payload|
      response = FakeResponse.new(code: 200, message: "OK", body: payload.to_json)
      Provider::Akahu.stub(:get, ->(_url, headers:, query: nil) { response }) do
        error = assert_raises(Provider::Akahu::AkahuError) do
          Provider::Akahu.new(app_token: "app", user_token: "user").get_pending_transactions_page
        end
        assert_equal :invalid_response, error.error_type
      end
    end
  end
end
