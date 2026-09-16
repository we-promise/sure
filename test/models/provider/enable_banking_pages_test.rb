require "test_helper"

class Provider::EnableBankingPagesTest < ActiveSupport::TestCase
  setup do
    @client = Provider::EnableBanking.allocate
    @client.stubs(:auth_headers).returns("Authorization" => "Bearer test-jwt", "Accept" => "application/json")
  end

  test "bounded native transactions retain exact numeric JSON and actual dates" do
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: "2026-09-01", date_to: "2026-09-14" })
      .to_return(status: 200, body: '{"transactions":[{"transaction_amount":{"amount":0.123456789012345678}}],"continuation_key":"next"}')
    result = @client.get_ingestion_transactions_page(**request_options)
    assert_equal BigDecimal("0.123456789012345678"), result[:items].first[:transaction_amount][:amount]
    assert_equal Date.new(2026, 9, 1), result[:date_from]
    assert_equal "next", result[:next_cursor]
    assert_equal result[:items], result[:evidence][:transactions]
  end

  test "period correction records its effective coverage" do
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: "2026-09-01", date_to: "2026-09-14" })
      .to_return(status: 422, body: '{"error":"WRONG_TRANSACTIONS_PERIOD","detail":{"date_from":"2026-09-10"}}')
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: "2026-09-10", date_to: "2026-09-14" })
      .to_return(status: 200, body: '{"transactions":[]}')
    result = @client.get_ingestion_transactions_page(**request_options)
    assert_equal Date.new(2026, 9, 10), result[:date_from]
    assert result[:narrowed_window]
    assert_nil result[:next_cursor]
  end

  test "fallback dates use the injected observation clock" do
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: "2025-01-01", date_to: "2026-09-14" })
      .to_return(status: 422, body: '{"code":"PERIOD_INVALID","detail":"provider-specific string"}')
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: (Date.new(2026, 9, 14) - 89).iso8601, date_to: "2026-09-14" })
      .to_return(status: 200, body: '{"transactions":[]}')
    result = @client.get_ingestion_transactions_page(**request_options.merge(date_from: Date.new(2025, 1, 1)))
    assert_equal Date.new(2026, 9, 14) - 89, result[:date_from]
  end

  test "continuation period error cannot restart under a different window" do
    stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
      .with(query: { transaction_status: "BOOK", date_from: "2026-09-01", date_to: "2026-09-14", continuation_key: "continue" })
      .to_return(status: 422, body: '{"error":"WRONG_TRANSACTIONS_PERIOD","detail":{"date_from":"2026-09-10"}}')
    assert_raises(Provider::EnableBanking::EnableBankingError) do
      @client.get_ingestion_transactions_page(**request_options.merge(continuation_key: "continue"))
    end
  end

  test "malformed success envelope and repeated continuation fail closed" do
    [ '{}', '{"transactions":null}', '{"transactions":["invalid"]}', '{"transactions":[],"continuation_key":"same"}' ].each do |body|
      stub_request(:get, "https://api.enablebanking.com/accounts/account-1/transactions")
        .with(query: { transaction_status: "BOOK", date_from: "2026-09-01", date_to: "2026-09-14", continuation_key: "same" })
        .to_return(status: 200, body: body)
      error = assert_raises(Provider::EnableBanking::EnableBankingError) do
        @client.get_ingestion_transactions_page(**request_options.merge(continuation_key: "same"))
      end
      assert_equal :invalid_response, error.error_type
    end
  end

  test "HTTP auth classification survives non-JSON errors without disclosing bodies" do
    stub_request(:get, "https://api.enablebanking.com/sessions/session-1").to_return(status: 401, body: "private-session-detail")
    error = assert_raises(Provider::EnableBanking::EnableBankingError) { @client.get_ingestion_session(session_id: "session-1") }
    assert_equal :unauthorized, error.error_type
    refute_includes error.message, "private-session-detail"
    assert_nil error.cause
  end

  test "PSU headers cannot replace authentication or inject new headers" do
    [ { "authorization" => "replacement" }, { "Psu-Ip-Address" => "192.0.2.3\r\nAuthorization: injected" } ].each do |headers|
      assert_raises(Provider::EnableBanking::EnableBankingError) do
        @client.get_ingestion_account_balances(account_id: "account-1", psu_headers: headers)
      end
    end
  end

  private
    def request_options
      { account_id: "account-1", date_from: Date.new(2026, 9, 1), date_to: Date.new(2026, 9, 14), reference_date: Date.new(2026, 9, 14) }
    end
end
