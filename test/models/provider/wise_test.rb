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

    stub_response = stub(code: 200, body: [].to_json)

    # Should send GET /v1/profiles with Bearer authorization
    Provider::Wise.expects(:get)
                  .with("#{Provider::Wise::BASE_URL}/v1/profiles", has_entries(headers: has_entry("Authorization", "Bearer test-token-abc")))
                  .returns(stub_response)

    provider.list_profiles
  end

  test "raises AuthenticationError on 401 response" do
    provider = Provider::Wise.new(api_token: "bad-token")

    stub_response = stub(code: 401, body: '{"error": "unauthorized"}')

    Provider::Wise.stubs(:get).returns(stub_response)

    assert_raises(Provider::Wise::AuthenticationError) do
      provider.list_profiles
    end
  end

  test "chunks statement requests into 365-day windows" do
    provider = Provider::Wise.new(api_token: "token-123")

    start_date = Date.new(2024, 1, 1)
    end_date   = Date.new(2025, 6, 1)   # ~517 days -> 2 windows expected

    stub_response = stub(code: 200, body: { transactions: [] }.to_json)

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
end
