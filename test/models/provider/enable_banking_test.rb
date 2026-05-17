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
end
