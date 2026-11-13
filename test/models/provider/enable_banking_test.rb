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

  test "start_authorization requests up to the configured ceiling when the ASPSP reports no limit" do
    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).once.with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      @provider.start_authorization(
        aspsp_name: "ING-DiBa AG",
        aspsp_country: "DE",
        redirect_url: "https://app.example.com/callback"
      )

      expected = Time.current + 180.days - 60.seconds
      assert_equal expected.iso8601, captured_body["access"]["valid_until"]
    end
  end

  test "start_authorization respects an ASPSP limit below the configured ceiling" do
    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).once.with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      @provider.start_authorization(
        aspsp_name: "ING-DiBa AG",
        aspsp_country: "DE",
        redirect_url: "https://app.example.com/callback",
        maximum_consent_validity: 60.days.to_i
      )

      expected = Time.current + 60.days - 60.seconds
      assert_equal expected.iso8601, captured_body["access"]["valid_until"]
    end
  end

  test "start_authorization caps an ASPSP limit above the configured ceiling" do
    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).once.with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      @provider.start_authorization(
        aspsp_name: "ING-DiBa AG",
        aspsp_country: "DE",
        redirect_url: "https://app.example.com/callback",
        maximum_consent_validity: 400.days.to_i
      )

      expected = Time.current + 180.days - 60.seconds
      assert_equal expected.iso8601, captured_body["access"]["valid_until"]
    end
  end

  test "start_authorization treats invalid maximum_consent_validity values as absent" do
    [ 0, -100, "abc", nil ].each do |bad_value|
      captured_body = nil
      response = OpenStruct.new(
        code: 200,
        body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
      )

      Provider::EnableBanking.expects(:post).once.with do |_url, options|
        captured_body = JSON.parse(options[:body])
        true
      end.returns(response)

      travel_to Time.zone.parse("2026-01-01 12:00:00") do
        @provider.start_authorization(
          aspsp_name: "ING-DiBa AG",
          aspsp_country: "DE",
          redirect_url: "https://app.example.com/callback",
          maximum_consent_validity: bad_value
        )

        expected = Time.current + 180.days - 60.seconds
        assert_equal expected.iso8601, captured_body["access"]["valid_until"]
      end
    end
  end

  test "start_authorization falls back to a shorter window when the ASPSP rejects the requested consent duration" do
    # Simulates the Trade Republic case (#2857): the ASPSP advertises exactly 90
    # days but still rejects the first (margin-adjusted) attempt.
    rejected_response = OpenStruct.new(
      code: 422,
      body: {
        code: 422,
        message: "ASPSP does not support consent validity more than 7776000 seconds in the future",
        error: "WRONG_REQUEST_PARAMETERS",
        detail: nil
      }.to_json
    )
    success_response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    captured_bodies = []
    Provider::EnableBanking.expects(:post).twice.with do |_url, options|
      captured_bodies << JSON.parse(options[:body])
      true
    end.returns(rejected_response, success_response)

    result = @provider.start_authorization(
      aspsp_name: "Trade Republic",
      aspsp_country: "DE",
      redirect_url: "https://app.example.com/callback",
      maximum_consent_validity: 90.days.to_i
    )

    assert_equal "auth_1", result[:authorization_id]
    first_valid_until = Time.iso8601(captured_bodies[0]["access"]["valid_until"])
    second_valid_until = Time.iso8601(captured_bodies[1]["access"]["valid_until"])
    assert second_valid_until < first_valid_until
  end

  test "start_authorization raises after exhausting the fallback ladder" do
    rejected_response = OpenStruct.new(
      code: 422,
      body: {
        message: "ASPSP does not support consent validity more than 7776000 seconds in the future",
        error: "WRONG_REQUEST_PARAMETERS"
      }.to_json
    )

    Provider::EnableBanking.expects(:post).times(3).returns(rejected_response, rejected_response, rejected_response)

    error = assert_raises Provider::EnableBanking::EnableBankingError do
      @provider.start_authorization(
        aspsp_name: "Trade Republic",
        aspsp_country: "DE",
        redirect_url: "https://app.example.com/callback",
        maximum_consent_validity: 90.days.to_i
      )
    end

    assert error.wrong_consent_validity?
  end

  test "start_authorization does not retry on an unrelated WRONG_REQUEST_PARAMETERS error" do
    rejected_response = OpenStruct.new(
      code: 422,
      body: {
        message: "redirect_url is not a valid URL",
        error: "WRONG_REQUEST_PARAMETERS"
      }.to_json
    )

    Provider::EnableBanking.expects(:post).once.returns(rejected_response)

    error = assert_raises Provider::EnableBanking::EnableBankingError do
      @provider.start_authorization(
        aspsp_name: "ING-DiBa AG",
        aspsp_country: "DE",
        redirect_url: "not-a-url"
      )
    end

    assert_not error.wrong_consent_validity?
  end

  test "start_authorization honors an overridden consent_days configuration" do
    original = Rails.configuration.x.enable_banking.consent_days
    Rails.configuration.x.enable_banking.consent_days = 90

    captured_body = nil
    response = OpenStruct.new(
      code: 200,
      body: { url: "https://api.enablebanking.com/auth/abc", authorization_id: "auth_1" }.to_json
    )

    Provider::EnableBanking.expects(:post).once.with do |_url, options|
      captured_body = JSON.parse(options[:body])
      true
    end.returns(response)

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      @provider.start_authorization(
        aspsp_name: "ING-DiBa AG",
        aspsp_country: "DE",
        redirect_url: "https://app.example.com/callback"
      )

      expected = Time.current + 90.days - 60.seconds
      assert_equal expected.iso8601, captured_body["access"]["valid_until"]
    end
  ensure
    Rails.configuration.x.enable_banking.consent_days = original
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
end
