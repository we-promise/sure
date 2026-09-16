require "test_helper"
require "ostruct"
require "openssl"

class Provider::EnableBankingTest < ActiveSupport::TestCase
  setup do
    key = OpenSSL::PKey::RSA.new(2048)
    @provider = Provider::EnableBanking.new(application_id: "test_app_id", client_certificate: key.to_pem)
  end

  test "get_account_transactions retries with corrected date_from from WRONG_TRANSACTIONS_PERIOD" do
    requested_queries = []

    validation_response = OpenStruct.new(
      code: 422,
      body: {
        error: "WRONG_TRANSACTIONS_PERIOD",
        detail: {
          message: "Maximum days in the past allowed for transaction list is 120",
          date_from: "2026-01-17"
        }
      }.to_json
    )

    success_response = OpenStruct.new(
      code: 200,
      body: { transactions: [] }.to_json
    )

    Provider::EnableBanking.expects(:get).twice.with do |_url, options|
      requested_queries << options[:query].dup
      true
    end.returns(validation_response, success_response)

    result = @provider.get_account_transactions(
      account_id: "acct_123",
      date_from: Date.new(2025, 12, 1),
      transaction_status: "BOOK"
    )

    assert_equal [], result[:transactions]
    assert_equal "2025-12-01", requested_queries.first[:date_from]
    assert_equal "2026-01-17", requested_queries.second[:date_from]
  end

  test "get_account_transactions falls back to a shorter window when no corrected date_from is given" do
    requested_queries = []

    # Some ASPSPs reject the period without suggesting a corrected date_from.
    validation_response = OpenStruct.new(
      code: 422,
      body: {
        error: "WRONG_TRANSACTIONS_PERIOD",
        detail: { message: "Requested time period out of bound." }
      }.to_json
    )
    success_response = OpenStruct.new(code: 200, body: { transactions: [] }.to_json)

    Provider::EnableBanking.expects(:get).twice.with do |_url, options|
      requested_queries << options[:query].dup
      true
    end.returns(validation_response, success_response)

    result = @provider.get_account_transactions(
      account_id: "acct_123",
      date_from: 6.months.ago.to_date,
      transaction_status: "BOOK"
    )

    assert_equal [], result[:transactions]
    assert_equal 6.months.ago.to_date.iso8601, requested_queries.first[:date_from]
    assert_equal 89.days.ago.to_date.iso8601, requested_queries.second[:date_from]
  end

  test "get_account_transactions skips fallback windows that do not advance the search" do
    requested_queries = []

    validation_response = OpenStruct.new(
      code: 422,
      body: { error: "WRONG_TRANSACTIONS_PERIOD", detail: { message: "out of bound" } }.to_json
    )
    success_response = OpenStruct.new(code: 200, body: { transactions: [] }.to_json)

    Provider::EnableBanking.expects(:get).twice.with do |_url, options|
      requested_queries << options[:query].dup
      true
    end.returns(validation_response, success_response)

    # A 45-day lookback is newer than the 89- and 60-day windows; only the
    # 30-day window moves the search forward, so it must be the one retried.
    result = @provider.get_account_transactions(
      account_id: "acct_123",
      date_from: 45.days.ago.to_date,
      transaction_status: "BOOK"
    )

    assert_equal [], result[:transactions]
    assert_equal 45.days.ago.to_date.iso8601, requested_queries.first[:date_from]
    assert_equal 30.days.ago.to_date.iso8601, requested_queries.second[:date_from]
  end

  test "validation errors expose parsed response data" do
    response = OpenStruct.new(
      code: 422,
      body: {
        error: "WRONG_TRANSACTIONS_PERIOD",
        detail: { date_from: "2026-01-17" }
      }.to_json
    )

    error = assert_raises Provider::EnableBanking::EnableBankingError do
      @provider.send(:handle_response, response)
    end

    assert_equal :validation_error, error.error_type
    assert_equal "WRONG_TRANSACTIONS_PERIOD", error.response_data[:error]
    assert_equal Date.new(2026, 1, 17), error.corrected_date_from
    assert error.wrong_transactions_period?
  end

  test "get_account_transactions retries a PERIOD_INVALID error with a string detail (N26 shape)" do
    requested_queries = []

    # N26 (via Enable Banking) rejects the period with a different payload
    # shape than WRONG_TRANSACTIONS_PERIOD: no "error" key, and "detail" is a
    # plain string instead of a hash, so no corrected date_from is available.
    period_invalid_response = OpenStruct.new(
      code: 400,
      body: {
        title: "Range is out of the last 90-day period",
        code: "PERIOD_INVALID",
        detail: "dateFrom=2025-12-11, dateTo=2026-03-23"
      }.to_json
    )
    success_response = OpenStruct.new(code: 200, body: { transactions: [] }.to_json)

    Provider::EnableBanking.expects(:get).twice.with do |_url, options|
      requested_queries << options[:query].dup
      true
    end.returns(period_invalid_response, success_response)

    result = @provider.get_account_transactions(
      account_id: "acct_123",
      date_from: 6.months.ago.to_date,
      transaction_status: "BOOK"
    )

    assert_equal [], result[:transactions]
    assert_equal 6.months.ago.to_date.iso8601, requested_queries.first[:date_from]
    assert_equal 89.days.ago.to_date.iso8601, requested_queries.second[:date_from]
  end

  test "PERIOD_INVALID errors with a string detail expose a nil corrected_date_from instead of raising" do
    response = OpenStruct.new(
      code: 400,
      body: {
        title: "Range is out of the last 90-day period",
        code: "PERIOD_INVALID",
        detail: "dateFrom=2025-12-11, dateTo=2026-03-23"
      }.to_json
    )

    error = assert_raises Provider::EnableBanking::EnableBankingError do
      @provider.send(:handle_response, response)
    end

    assert_equal :bad_request, error.error_type
    assert error.wrong_transactions_period?
    assert_nil error.corrected_date_from
  end

  test "start_authorization includes auth_method in the request body when provided" do
    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    @provider.start_authorization(
      aspsp_name: "VR Bank in Holstein",
      aspsp_country: "DE",
      redirect_url: "https://app.example.com/callback",
      auth_method: "decoupled_app"
    )

    assert_equal "decoupled_app", captured_body["auth_method"]
  end

  test "start_authorization omits auth_method when not provided" do
    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    @provider.start_authorization(
      aspsp_name: "ING-DiBa AG",
      aspsp_country: "DE",
      redirect_url: "https://app.example.com/callback"
    )

    assert_not captured_body.key?("auth_method")
  end
  test "bad request errors expose parsed response data" do
    response = OpenStruct.new(
      code: 400,
      body: {
        error: "BALANCES_UNAVAILABLE",
        detail: { account_id: "redacted" }
      }.to_json
    )

    error = assert_raises Provider::EnableBanking::EnableBankingError do
      @provider.send(:handle_response, response)
    end

    assert_equal :bad_request, error.error_type
    assert_equal "BALANCES_UNAVAILABLE", error.response_data[:error]
    assert_equal "redacted", error.response_data.dig(:detail, :account_id)
  end

  test "single use consent POSTs disable transport retries and redirects" do
    Provider::EnableBanking.expects(:post).with do |url, options|
      url == "#{Provider::EnableBanking::BASE_URL}/auth" && options[:max_retries] == 0 && options[:follow_redirects] == false
    end.once.raises(Net::ReadTimeout)
    assert_raises(Provider::EnableBanking::EnableBankingError) do
      @provider.start_authorization(aspsp_name: "Bank", aspsp_country: "FI", redirect_url: "https://example.com/callback", state: "signed-state")
    end
    Provider::EnableBanking.expects(:post).with do |url, options|
      url == "#{Provider::EnableBanking::BASE_URL}/sessions" && options[:max_retries] == 0 && options[:follow_redirects] == false
    end.once.raises(Net::ReadTimeout)
    assert_raises(Provider::EnableBanking::EnableBankingError) { @provider.create_session(code: "single-use-code") }
  end

  test "revocation disables transport retries and does not interpret missing remote session as proof of our DELETE" do
    response = OpenStruct.new(code: 404, body: "{}")
    Provider::EnableBanking.expects(:delete).with do |url, options|
      url == "#{Provider::EnableBanking::BASE_URL}/sessions/original" && options[:max_retries] == 0 && options[:follow_redirects] == false
    end.once.returns(response)
    error = assert_raises(Provider::EnableBanking::EnableBankingError) { @provider.delete_session(session_id: "original") }
    assert_equal :not_found, error.error_type
  end
end
