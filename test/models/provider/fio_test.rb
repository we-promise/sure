require "test_helper"

class Provider::FioTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :message, keyword_init: true)

  STATEMENT_BODY = {
    accountStatement: {
      info: {
        accountId: "2400222222",
        bankId: "2010",
        currency: "CZK",
        iban: "CZ7920100000002400222222",
        bic: "FIOBCZPPXXX",
        closingBalance: 195.01
      },
      transactionList: {
        transaction: [
          { column22: { value: 1_148_734_530, name: "ID pohybu", id: 22 } }
        ]
      }
    }
  }.to_json

  test "requests the period endpoint with the token in the path and returns the statement" do
    requests = []

    Provider::Fio.stub(:get, ->(url, headers:) {
      requests << { url: url, headers: headers }
      FakeResponse.new(code: 200, message: "OK", body: STATEMENT_BODY)
    }) do
      statement = Provider::Fio.new("fio-token").get_statement(
        from: Date.new(2026, 6, 1),
        to: Date.new(2026, 6, 30)
      )

      assert_equal "2400222222", statement.dig(:info, :accountId)
      assert_equal [ 1_148_734_530 ], statement.dig(:transactionList, :transaction).map { |tx| tx.dig(:column22, :value) }
    end

    assert_equal(
      "https://fioapi.fio.cz/v1/rest/fio-token/periods/2026-06-01/2026-06-30/transactions.json",
      requests.sole[:url]
    )
  end

  # Fio answers a range with no movements with an empty body. Reading that as a failure
  # would stall the cursor on a quiet account forever.
  test "treats an empty response body as a statement with no movements" do
    Provider::Fio.stub(:get, ->(_url, headers:) { FakeResponse.new(code: 200, message: "OK", body: "") }) do
      statement = Provider::Fio.new("fio-token").get_statement(from: Date.current, to: Date.current)

      assert_empty statement
    end
  end

  # Section 8 of the API documentation. None of these statuses mean what the HTTP status
  # alone suggests, and each one the caller handles differently: 409 defers, 422 clamps
  # the window, 413 asks the user for a shorter one, 500 is a dead token.
  test "maps documented error statuses onto typed errors" do
    {
      409 => [ Provider::Fio::RateLimitError, :rate_limited ],
      413 => [ Provider::Fio::TooManyItemsError, :too_many_items ],
      422 => [ Provider::Fio::HistoryLockedError, :history_locked ],
      500 => [ Provider::Fio::Error, :unauthorized ],
      404 => [ Provider::Fio::Error, :bad_request ],
      503 => [ Provider::Fio::Error, :server_error ]
    }.each do |status, (error_class, failure_code)|
      Provider::Fio.stub(:get, ->(_url, headers:) { FakeResponse.new(code: status, message: "", body: "") }) do
        error = assert_raises(error_class) do
          Provider::Fio.new("fio-token").get_statement(from: Date.current, to: Date.current)
        end

        assert_equal failure_code, error.failure_code, "status #{status}"
      end
    end
  end

  test "rejects a range that ends before it starts without calling the API" do
    called = false

    Provider::Fio.stub(:get, ->(_url, headers:) { called = true }) do
      error = assert_raises(Provider::Fio::Error) do
        Provider::Fio.new("fio-token").get_statement(from: Date.new(2026, 6, 30), to: Date.new(2026, 6, 1))
      end

      assert_equal :bad_request, error.failure_code
    end

    refute called
  end

  test "refuses to build a client without a token" do
    error = assert_raises(Provider::Fio::Error) { Provider::Fio.new("  ") }

    assert_equal :configuration_error, error.failure_code
  end

  # The token is a path segment, so an exception message or debug entry that echoed the
  # URL would leak full account access into logs.
  test "keeps the token out of error messages and diagnostics" do
    Provider::Fio.stub(:get, ->(_url, headers:) { FakeResponse.new(code: 418, message: "", body: "teapot") }) do
      error = assert_raises(Provider::Fio::Error) do
        Provider::Fio.new("sekret-token").get_statement(from: Date.current, to: Date.current)
      end

      refute_includes error.message, "sekret-token"
    end

    entry = DebugLogEntry.where(provider_key: "fio").order(:created_at).last
    assert_equal "Fio API returned an unexpected response status", entry.message
    refute_includes entry.metadata.to_json, "sekret-token"
  end
end
