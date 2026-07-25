require "test_helper"

class Provider::RedbarkTest < ActiveSupport::TestCase
  test "initializes with api key" do
    provider = Provider::Redbark.new(api_key: "rbk_live_test")
    assert_equal "rbk_live_test", provider.api_key
  end

  test "raises configuration error when api key blank" do
    assert_raises(Provider::Redbark::ConfigurationError) do
      Provider::Redbark.new(api_key: "")
    end
  end

  test "error includes error_type" do
    error = Provider::Redbark::Error.new("Test error", :unauthorized)
    assert_equal "Test error", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "error defaults error_type to unknown" do
    error = Provider::Redbark::Error.new("Test error")
    assert_equal :unknown, error.error_type
  end

  test "rate limit and server errors are typed for retry handling" do
    assert Provider::Redbark::RateLimitError.new("limited", :rate_limited).is_a?(Provider::Redbark::Error)
    assert Provider::Redbark::ServerError.new("boom", :server_error).is_a?(Provider::Redbark::Error)
  end
end
