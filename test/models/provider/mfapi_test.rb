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

  test "fetch_security_price looks back seven days and returns the nearest earlier NAV" do
    stub_mfapi("/mf/119551", { "startDate" => "2024-02-29", "endDate" => "2024-03-07" }, {
      "data" => [
        { "date" => "08-03-2024", "nav" => "1650.00000" },
        { "date" => "05-03-2024", "nav" => "1640.00000" },
        { "date" => "04-03-2024", "nav" => "1630.00000" }
      ]
    })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert response.success?
    assert_equal [ Date.new(2024, 3, 5), 1640.0 ], [ response.data.date, response.data.price ]
  end

  test "fetch_security_price with no NAV in the window returns a failed response" do
    stub_mfapi("/mf/119551", {}, { "data" => [] })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert_not response.success?
    # RateLimitable#default_error_transformer re-wraps InvalidSecurityPriceError as the base Error.
    assert_kind_of Provider::Mfapi::Error, response.error
    assert_equal "No NAV found for scheme 119551 on or before 2024-03-07", response.error.message
  end

  test "fetch_security_price returns the NAV dated on the requested day over a later one" do
    stub_mfapi("/mf/119551", { "startDate" => "2024-02-29", "endDate" => "2024-03-07" }, {
      "data" => [
        { "date" => "08-03-2024", "nav" => "1650.00000" },
        { "date" => "07-03-2024", "nav" => "1645.00000" }
      ]
    })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert response.success?
    assert_equal [ Date.new(2024, 3, 7), 1645.0 ], [ response.data.date, response.data.price ]
  end

  test "fetch_security_price with only later NAVs returns a failed response" do
    stub_mfapi("/mf/119551", { "startDate" => "2024-02-29", "endDate" => "2024-03-07" }, {
      "data" => [
        { "date" => "09-03-2024", "nav" => "1660.00000" },
        { "date" => "08-03-2024", "nav" => "1650.00000" }
      ]
    })

    response = build_provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert_not response.success?
    assert_kind_of Provider::Mfapi::Error, response.error
    assert_equal "No NAV found for scheme 119551 on or before 2024-03-07", response.error.message
  end

  private
    def build_provider
      provider = Provider::Mfapi.new
      provider.stubs(:throttle_request)
      provider
    end

    def stub_mfapi(path, params, body)
      stub_request(:get, "https://api.mfapi.in#{path}")
        .with(query: hash_including(params))
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end
end
