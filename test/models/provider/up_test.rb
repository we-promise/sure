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
    assert_equal "2026-01-01T00:00:00Z", requests.first[:query]["filter[since]"]
    assert_equal 100, requests.first[:query]["page[size]"]
    # Pagination follows the absolute next URL with no extra query params.
    assert_equal next_url, requests.second[:url]
    assert_nil requests.second[:query]
  end

  test "stops paginating when the API repeats the same next cursor" do
    repeating_url = "https://api.up.com.au/api/v1/accounts/acc_123/transactions?page%5Bafter%5D=loop"
    page = FakeResponse.new(
      code: 200,
      message: "OK",
      body: {
        data: [ { type: "transactions", id: "tx_1", attributes: { status: "SETTLED" }, relationships: { account: { data: { id: "acc_123" } } } } ],
        links: { prev: nil, next: repeating_url }
      }.to_json
    )
    request_count = 0

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      request_count += 1
      raise "infinite pagination loop" if request_count > 5

      page
    }) do
      client = Provider::Up.new("up-access-token")
      transactions = client.get_account_transactions(account_id: "acc_123")

      # First request + one follow of the repeated cursor, then the guard stops.
      assert_equal 2, request_count
      assert_equal [ "tx_1", "tx_1" ], transactions.map { |tx| tx[:id] }
    end
  end

  test "refuses to follow a pagination link pointing at a non-Up host" do
    evil_url = "https://evil.example.com/api/v1/accounts/acc_123/transactions?page%5Bafter%5D=x"
    first_page = FakeResponse.new(
      code: 200,
      message: "OK",
      body: {
        data: [ { type: "transactions", id: "tx_1", attributes: { status: "SETTLED" }, relationships: { account: { data: { id: "acc_123" } } } } ],
        links: { prev: nil, next: evil_url }
      }.to_json
    )
    requested_urls = []

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      requested_urls << url
      first_page
    }) do
      client = Provider::Up.new("up-access-token")

      error = assert_raises(Provider::Up::UpError) do
        client.get_account_transactions(account_id: "acc_123")
      end
      assert_equal :invalid_url, error.error_type
    end

    # The bearer token must never be sent to the foreign host.
    assert_not_includes requested_urls, evil_url
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

  test "flattens transaction relationships including transferAccount" do
    response = FakeResponse.new(
      code: 200,
      message: "OK",
      body: {
        data: [
          {
            type: "transactions", id: "tx_xfer",
            attributes: { status: "SETTLED", description: "Transfer to Savings" },
            relationships: {
              account: { data: { id: "acc_123" } },
              category: { data: nil },
              transferAccount: { data: { id: "acc_saver" } }
            }
          },
          {
            type: "transactions", id: "tx_plain",
            attributes: { status: "SETTLED", description: "Coffee" },
            relationships: {
              account: { data: { id: "acc_123" } },
              category: { data: { id: "restaurants-and-cafes" } },
              transferAccount: { data: nil }
            }
          }
        ],
        links: { prev: nil, next: nil }
      }.to_json
    )

    # The stub deliberately ignores the query: keyword: this test exercises only
    # response flattening, not the request params (pagination/date filters), which
    # are covered by the pagination tests above.
    Provider::Up.stub(:get, ->(_url, headers:, query: nil) { response }) do
      transactions = Provider::Up.new("up-access-token").get_account_transactions(account_id: "acc_123")

      assert_equal "acc_saver", transactions.first[:transfer_account_id]
      assert_equal "restaurants-and-cafes", transactions.second[:category_id]
      assert_nil transactions.second[:transfer_account_id]
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

  test "bounded account reads return one page without following the continuation" do
    next_url = "https://api.up.com.au/api/v1/accounts?page%5Bafter%5D=second"
    response = FakeResponse.new(code: 200, message: "OK", body: {
      data: [ { id: "acc_123", type: "accounts", attributes: { displayName: "Spending" } } ],
      links: { next: next_url }
    }.to_json)
    requests = []

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, headers: headers, query: query }
      response
    }) do
      page = Provider::Up.new("up-access-token").get_accounts_page

      assert_equal [ "acc_123" ], page[:items].map { |item| item[:id] }
      assert_equal "Spending", page[:items].first[:displayName]
      assert_equal next_url, page[:next_cursor]
    end

    assert_equal 1, requests.size
    assert_equal "https://api.up.com.au/api/v1/accounts", requests.first[:url]
    assert_equal "Bearer up-access-token", requests.first[:headers]["Authorization"]
  end

  test "bounded transaction reads encode account IDs apply date filters and retain relationship hints" do
    response = FakeResponse.new(code: 200, message: "OK", body: {
      data: [ {
        id: "tx_123", type: "transactions", attributes: { status: "HELD" },
        relationships: {
          account: { data: { id: "account/with space" } }, category: { data: { id: "groceries" } },
          transferAccount: { data: { id: "acc_saver" } }
        }
      } ], links: { next: nil }
    }.to_json)
    requests = []

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, query: query }
      response
    }) do
      page = Provider::Up.new("up-access-token").get_account_transactions_page(
        account_id: "account/with space", since: Date.new(2026, 1, 1), until_date: Date.new(2026, 1, 31)
      )

      assert_nil page[:next_cursor]
      assert_equal "HELD", page[:items].first[:status]
      assert_equal "account/with space", page[:items].first[:account_id]
      assert_equal "groceries", page[:items].first[:category_id]
      assert_equal "acc_saver", page[:items].first[:transfer_account_id]
    end

    assert_equal 1, requests.size
    assert_equal "https://api.up.com.au/api/v1/accounts/account%2Fwith%20space/transactions", requests.first[:url]
    assert_equal({ "page[size]" => 100, "filter[since]" => "2026-01-01T00:00:00Z", "filter[until]" => "2026-01-31T00:00:00Z" }, requests.first[:query])
  end

  test "bounded continuation requests use only the opaque cursor URL" do
    cursor = "https://api.up.com.au/api/v1/accounts/acc_123/transactions?page%5Bafter%5D=second"
    response = FakeResponse.new(code: 200, message: "OK", body: { data: [], links: { next: nil } }.to_json)
    requests = []

    Provider::Up.stub(:get, ->(url, headers:, query: nil) {
      requests << { url: url, query: query }
      response
    }) do
      page = Provider::Up.new("up-access-token").get_account_transactions_page(
        account_id: "acc_123", cursor: cursor, since: Date.new(2026, 1, 1), until_date: Date.new(2026, 1, 31)
      )
      assert_empty page[:items]
      assert_nil page[:next_cursor]
    end

    assert_equal [ { url: cursor, query: nil } ], requests
  end

  test "bounded reads reject malformed pagination envelopes before returning success" do
    malformed_payloads = [
      {}, { data: [], links: {} }, { data: nil, links: { next: nil } },
      { data: [], links: { next: false } }, { data: [], links: { next: "" } },
      { data: [], links: { next: 123 } }, { data: [ nil ], links: { next: nil } },
      { data: [ { type: "transactions", attributes: {} } ], links: { next: nil } },
      { data: [ { type: "accounts", attributes: nil } ], links: { next: nil } }
    ]

    malformed_payloads.each do |payload|
      response = FakeResponse.new(code: 200, message: "OK", body: payload.to_json)
      Provider::Up.stub(:get, ->(_url, headers:, query: nil) { response }) do
        error = assert_raises(Provider::Up::UpError) { Provider::Up.new("up-access-token").get_accounts_page }
        assert_equal :invalid_response, error.error_type
      end
    end
  end

  test "bounded reads reject foreign continuations before persisting their cursor" do
    [ "https://evil.example.test/accounts", "http://api.up.com.au/api/v1/accounts" ].each do |cursor|
      response = FakeResponse.new(code: 200, message: "OK", body: { data: [], links: { next: cursor } }.to_json)
      requested_urls = []
      Provider::Up.stub(:get, ->(url, headers:, query: nil) {
        requested_urls << url
        response
      }) do
        error = assert_raises(Provider::Up::UpError) { Provider::Up.new("up-access-token").get_accounts_page }
        assert_equal :invalid_url, error.error_type
      end

      assert_equal [ "https://api.up.com.au/api/v1/accounts" ], requested_urls
    end
  end

  test "bounded reads reject an untrusted initial cursor without sending credentials" do
    Provider::Up.expects(:get).never

    error = assert_raises(Provider::Up::UpError) do
      Provider::Up.new("up-access-token").get_accounts_page(cursor: "https://evil.example.test/accounts")
    end

    assert_equal :invalid_url, error.error_type
  end

  test "bounded reads preserve rate limit and authentication failures" do
    { 401 => :unauthorized, 429 => :rate_limited }.each do |status, expected_type|
      response = FakeResponse.new(code: status, message: "Failure", body: "{}")
      Provider::Up.stub(:get, ->(_url, headers:, query: nil) { response }) do
        error = assert_raises(Provider::Up::UpError) do
          Provider::Up.new("up-access-token").get_account_transactions_page(account_id: "acc_123")
        end
        assert_equal expected_type, error.error_type
      end
    end
  end

  test "raises configuration error when token blank" do
    error = assert_raises Provider::Up::UpError do
      Provider::Up.new("")
    end

    assert_equal :configuration_error, error.error_type
  end
end
