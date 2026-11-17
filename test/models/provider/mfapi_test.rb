require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  test "client sets explicit open and read timeouts" do
    provider = Provider::Mfapi.new
    options = provider.send(:client).options

    assert_equal 5, options.open_timeout
    assert_equal 20, options.timeout
  end

  test "a timed-out request returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    stub_request(:get, %r{\Ahttps://api\.mfapi\.in/}).to_timeout

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
  end
end
