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

  test "fetch_security_price with only later NAVs returns a failed response" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    stub_nav_response(
      symbol: "119551",
      start_date: Date.new(2024, 2, 29),
      end_date: Date.new(2024, 3, 7),
      data: [
        { "date" => "09-03-2024", "nav" => "1660.00000" },
        { "date" => "08-03-2024", "nav" => "1650.00000" }
      ]
    )

    response = provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert_not response.success?
    assert_equal "No NAV found for scheme 119551 on or before 2024-03-07", response.error.message
  end

  test "fetch_security_price returns the nearest NAV on or before the date" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    stub_nav_response(
      symbol: "119551",
      start_date: Date.new(2024, 2, 29),
      end_date: Date.new(2024, 3, 7),
      data: [
        { "date" => "09-03-2024", "nav" => "1660.00000" },
        { "date" => "06-03-2024", "nav" => "1640.00000" },
        { "date" => "05-03-2024", "nav" => "1630.00000" }
      ]
    )

    response = provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert response.success?
    assert_equal Date.new(2024, 3, 6), response.data.date
    assert_equal 1640.0, response.data.price
  end

  test "fetch_security_price prefers a NAV dated on the requested day over a later one" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    stub_nav_response(
      symbol: "119551",
      start_date: Date.new(2024, 2, 29),
      end_date: Date.new(2024, 3, 7),
      data: [
        { "date" => "09-03-2024", "nav" => "1660.00000" },
        { "date" => "07-03-2024", "nav" => "1650.00000" }
      ]
    )

    response = provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert response.success?
    assert_equal Date.new(2024, 3, 7), response.data.date
    assert_equal 1650.0, response.data.price
  end

  test "fetch_security_price with an empty window returns a failed response" do
    provider = Provider::Mfapi.new
    provider.stubs(:throttle_request)
    stub_nav_response(
      symbol: "119551",
      start_date: Date.new(2024, 2, 29),
      end_date: Date.new(2024, 3, 7),
      data: []
    )

    response = provider.fetch_security_price(symbol: "119551", exchange_operating_mic: "XBOM", date: Date.new(2024, 3, 7))

    assert_not response.success?
    assert_equal "No NAV found for scheme 119551 on or before 2024-03-07", response.error.message
  end

  private

    def stub_nav_response(symbol:, start_date:, end_date:, data:)
      stub_request(:get, "https://api.mfapi.in/mf/#{symbol}")
        .with(query: { "startDate" => start_date.to_s, "endDate" => end_date.to_s })
        .to_return(
          status: 200,
          body: { data: data }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
end
