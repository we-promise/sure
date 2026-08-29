require "test_helper"

class Provider::LunchflowTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Lunchflow.new("test_key", base_url: "https://www.lunchflow.app/api/v1")
  end

  test "retries a wrapped GoCardless rate limit and preserves its type" do
    rate_limited = response(
      503,
      {
        error: "GCRateLimited",
        message: "Bank data is temporarily unavailable. This usually resolves within a minute."
      }.to_json,
      "Service Unavailable"
    )
    success = response(200, { transactions: [] }.to_json, "OK")

    Provider::Lunchflow.expects(:get).times(2).returns(rate_limited, success)
    @provider.expects(:sleep).with(Provider::Lunchflow::DEFAULT_RATE_LIMIT_DELAY).once

    result = assert_difference -> { DebugLogEntry.with_provider_key("lunchflow").count }, 1 do
      @provider.get_account_transactions("acct-1")
    end

    assert_equal({ transactions: [] }, result)
    entry = DebugLogEntry.with_provider_key("lunchflow").recent.first
    assert_equal "rate_limited", entry.metadata["error_type"]
    assert_equal 1, entry.metadata["retry_attempt"]
    assert_equal Provider::Lunchflow::DEFAULT_RATE_LIMIT_DELAY, entry.metadata["retry_delay"]
  end

  test "uses the retry delay from a wrapped upstream 429 message" do
    rate_limited = response(
      500,
      {
        error: "ProviderError",
        message: "API request failed (429 - Rate limit exceeded). Please try again in 7 seconds."
      }.to_json,
      "Internal Server Error"
    )
    success = response(200, { balance: { amount: "10.00", currency: "EUR" } }.to_json, "OK")

    Provider::Lunchflow.expects(:get).times(2).returns(rate_limited, success)
    @provider.expects(:sleep).with(7.0).once

    assert_equal "10.00", @provider.get_account_balance("acct-1").dig(:balance, :amount)
  end

  test "uses a bounded Retry-After header for a direct 429" do
    rate_limited = response(
      429,
      { error: "RateLimited" }.to_json,
      "Too Many Requests",
      headers: { "retry-after" => "120" }
    )
    success = response(200, { transactions: [] }.to_json, "OK")

    Provider::Lunchflow.expects(:get).times(2).returns(rate_limited, success)
    @provider.expects(:sleep).with(Provider::Lunchflow::MAX_RETRY_DELAY).once

    assert_equal({ transactions: [] }, @provider.get_account_transactions("acct-1"))
  end

  test "retries transient server errors with exponential backoff" do
    unavailable = response(502, { error: "BadGateway" }.to_json, "Bad Gateway")
    success = response(200, { accounts: [] }.to_json, "OK")

    Provider::Lunchflow.expects(:get).times(2).returns(unavailable, success)
    @provider.stubs(:rand).returns(0)
    @provider.expects(:sleep).with(Provider::Lunchflow::INITIAL_RETRY_DELAY).once

    assert_equal({ accounts: [] }, @provider.get_accounts)
  end

  test "retries server errors with non-object JSON bodies" do
    unavailable = response(502, [].to_json, "Bad Gateway")
    success = response(200, { accounts: [] }.to_json, "OK")

    Provider::Lunchflow.expects(:get).times(2).returns(unavailable, success)
    @provider.stubs(:rand).returns(0)
    @provider.expects(:sleep).with(Provider::Lunchflow::INITIAL_RETRY_DELAY).once

    assert_equal({ accounts: [] }, @provider.get_accounts)
  end

  test "retries transient network errors" do
    success = response(200, { accounts: [] }.to_json, "OK")

    Provider::Lunchflow.expects(:get)
      .times(2)
      .raises(Net::ReadTimeout.new("timed out"))
      .then
      .returns(success)
    @provider.stubs(:rand).returns(0)
    @provider.expects(:sleep).with(Provider::Lunchflow::INITIAL_RETRY_DELAY).once

    assert_equal({ accounts: [] }, @provider.get_accounts)
  end

  test "raises the typed rate limit error after retries are exhausted" do
    rate_limited = response(
      503,
      { error: "GCRateLimited", message: "Bank data is temporarily unavailable." }.to_json,
      "Service Unavailable"
    )

    Provider::Lunchflow.expects(:get).times(Provider::Lunchflow::MAX_RATE_LIMIT_RETRIES + 1).returns(rate_limited)
    @provider.stubs(:sleep)

    error = nil
    assert_difference -> { DebugLogEntry.with_provider_key("lunchflow").count }, 2 do
      error = assert_raises(Provider::Lunchflow::LunchflowError) do
        @provider.get_accounts
      end
    end

    assert_equal :rate_limited, error.error_type
    entry = DebugLogEntry.with_provider_key("lunchflow").recent.first
    assert_equal "Lunch Flow API request failed", entry.message
    assert_equal "GET /accounts", entry.metadata["operation"]
    assert_equal 503, entry.metadata["status"]
    assert_equal "rate_limited", entry.metadata["error_type"]
    assert_equal Provider::Lunchflow::MAX_RATE_LIMIT_RETRIES, entry.metadata["retry_attempts"]
  end

  test "does not retry authentication failures" do
    unauthorized = response(401, { error: "Unauthorized" }.to_json, "Unauthorized")

    Provider::Lunchflow.expects(:get).once.returns(unauthorized)
    @provider.expects(:sleep).never

    error = nil
    assert_difference -> { DebugLogEntry.with_provider_key("lunchflow").count }, 1 do
      error = assert_raises(Provider::Lunchflow::LunchflowError) do
        @provider.get_accounts
      end
    end

    assert_equal :unauthorized, error.error_type
    entry = DebugLogEntry.with_provider_key("lunchflow").recent.first
    assert_equal "GET /accounts", entry.metadata["operation"]
    assert_equal 401, entry.metadata["status"]
    assert_equal "unauthorized", entry.metadata["error_type"]
    assert_not_includes entry.metadata.to_json, unauthorized.body
  end

  private

    def response(code, body, message, headers: {})
      OpenStruct.new(code: code, body: body, message: message, headers: headers)
    end
end
