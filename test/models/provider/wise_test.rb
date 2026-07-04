# frozen_string_literal: true

require "test_helper"

class Provider::WiseTest < ActiveSupport::TestCase
  test "raises ConfigurationError when api_token is nil" do
    assert_raises(Provider::Wise::ConfigurationError) do
      Provider::Wise.new(api_token: nil)
    end
  end

  test "raises ConfigurationError when api_token is empty string" do
    assert_raises(Provider::Wise::ConfigurationError) do
      Provider::Wise.new(api_token: "")
    end
  end

  test "raises ConfigurationError when api_token is whitespace only" do
    assert_raises(Provider::Wise::ConfigurationError) do
      Provider::Wise.new(api_token: "   ")
    end
  end

  test "sends Authorization header as Bearer token on API requests" do
    provider = Provider::Wise.new(api_token: "test-token-abc")

    stub_response = OpenStruct.new(code: 200, body: [].to_json)

    # Should send GET /v1/profiles with Bearer authorization
    Provider::Wise.expects(:get)
                  .with("#{Provider::Wise::BASE_URL}/v1/profiles", has_entries(headers: has_entry("Authorization", "Bearer test-token-abc")))
                  .returns(stub_response)

    provider.list_profiles
  end

  test "raises AuthenticationError on 401 response" do
    provider = Provider::Wise.new(api_token: "bad-token")

    stub_response = OpenStruct.new(code: 401, body: '{"error": "unauthorized"}')

    Provider::Wise.stubs(:get).returns(stub_response)

    assert_raises(Provider::Wise::AuthenticationError) do
      provider.list_profiles
    end
  end

  test "chunks statement requests into 365-day windows" do
    provider = Provider::Wise.new(api_token: "token-123")

    start_date = Date.new(2024, 1, 1)
    end_date   = Date.new(2025, 6, 1)   # ~517 days -> 2 windows expected

    stub_response = OpenStruct.new(code: 200, body: { transactions: [] }.to_json)

    call_count = 0
    Provider::Wise.stubs(:get).with do |_url, _opts|
      call_count += 1
      true
    end.returns(stub_response)

    provider.get_statement(
      profile_id: "12345",
      balance_id: "67890",
      currency:   "USD",
      start_date: start_date,
      end_date:   end_date
    )

    assert_equal 2, call_count, "Expected 2 API calls for a 517-day range chunked at 365 days"
  end

  test "retries network errors and raises Error after max retries exhausted" do
    provider = Provider::Wise.new(api_token: "test-token")
    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    attempt_count = 0
    Provider::Wise.stubs(:get).with { |*| attempt_count += 1; true }.raises(SocketError, "connection failed")

    error = assert_raises(Provider::Wise::Error) do
      provider.list_profiles
    end

    assert_equal Provider::Wise::MAX_RETRIES + 1, attempt_count
    assert_match "Network error after #{Provider::Wise::MAX_RETRIES} retries", error.message
  end

  test "retries on 429 rate limit and raises Error after max retries exhausted" do
    provider = Provider::Wise.new(api_token: "test-token")
    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    stub_429 = OpenStruct.new(code: 429, body: "{}")
    Provider::Wise.stubs(:get).returns(stub_429)

    error = assert_raises(Provider::Wise::Error) do
      provider.list_profiles
    end

    assert_match "Network error after #{Provider::Wise::MAX_RETRIES} retries", error.message
  end

  test "retries on 5xx server error and raises Error after max retries exhausted" do
    provider = Provider::Wise.new(api_token: "test-token")
    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    stub_503 = OpenStruct.new(code: 503, body: "{}")
    Provider::Wise.stubs(:get).returns(stub_503)

    assert_raises(Provider::Wise::Error) do
      provider.list_profiles
    end
  end
end
