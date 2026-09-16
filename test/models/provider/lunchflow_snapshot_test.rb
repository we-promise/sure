require "test_helper"
require "ostruct"

class Provider::LunchflowSnapshotTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Lunchflow.new("private-api-key", base_url: "https://lunch.example/v1")
  end

  test "native reader retains exact decimals and forwards the custom endpoint and authentication" do
    Provider::Lunchflow.expects(:get).with("https://lunch.example/v1/accounts", headers: {
      "x-api-key" => "private-api-key", "Content-Type" => "application/json", "Accept" => "application/json"
    }).returns(OpenStruct.new(code: 200, body: '{"accounts":[],"exact":1234567890123456.123456789012345678}'))
    result = @provider.get_accounts_snapshot
    assert_equal BigDecimal("1234567890123456.123456789012345678"), result.fetch(:exact)
  end

  test "bounded reader escapes account IDs and omits disabled pending parameter" do
    Provider::Lunchflow.expects(:get).with("https://lunch.example/v1/accounts/account%2Fone/transactions?start_date=2026-01-01&end_date=2026-01-31", anything)
      .returns(OpenStruct.new(code: 200, body: '{"transactions":[],"total":0}'))
    assert_equal [], @provider.get_account_transactions_snapshot("account/one",
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), include_pending: false).fetch(:transactions)
  end

  test "holdings unsupported is distinct from an empty supported snapshot" do
    Provider::Lunchflow.expects(:get).returns(OpenStruct.new(code: 501, body: "unsupported"))
    assert_equal({ holdings_not_supported: true }, @provider.get_account_holdings_snapshot("account"))
  end

  test "terminal errors retain retry classification without exposing credentials or raw response text" do
    DebugLogEntry.stubs(:capture)
    Provider::Lunchflow.expects(:get).returns(OpenStruct.new(code: 400, body: '{"error":"private-api-key and private response"}'))
    error = assert_raises(Provider::Lunchflow::LunchflowError) { @provider.get_accounts_snapshot }
    assert_equal :bad_request, error.error_type
    assert_equal 400, error.status
    refute_includes error.message, "private-api-key"
    refute_includes error.message, "private response"
    assert_nil error.cause
  end
end
