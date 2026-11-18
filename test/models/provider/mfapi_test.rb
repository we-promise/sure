require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  test "a timed-out request returns a failed response" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(Faraday::TimeoutError.new("execution expired"))

    result = provider.fetch_security_info(symbol: "125497", exchange_operating_mic: "XBOM")

    assert_not result.success?
    assert_instance_of Provider::Mfapi::Error, result.error
  end
end
