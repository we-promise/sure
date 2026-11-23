require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  include ProviderTestHelper

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
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_timeout
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::ConnectionFailed, errors.last
    assert_kind_of Net::OpenTimeout, errors.last.wrapped_exception
  end

  test "a read timeout is retried and returns a failed response with the provider's Error" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    search = stub_request(:get, %r{\Ahttps://api\.mfapi\.in/mf/search}).to_raise(Net::ReadTimeout)
    errors = capture_transformed_errors(provider)

    response = provider.search_securities("TEST")

    assert_not response.success?
    assert_instance_of Provider::Mfapi::Error, response.error
    assert_requested search, times: 4
    assert_kind_of Faraday::TimeoutError, errors.last
  end
end
