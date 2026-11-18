require "test_helper"

class Provider::PropertiesapiTest < ActiveSupport::TestCase
  PROPERTY_URL = "https://api.propertiesapi.com/v1/zillow/property".freeze
  ADDRESS = "2640 Steiner St, San Francisco, CA 94115".freeze

  setup do
    # The WebMock stubs match PROPERTY_URL, so a developer's PROPERTIESAPI_URL
    # must not send these requests elsewhere.
    @previous_propertiesapi_url = ENV["PROPERTIESAPI_URL"]
    ENV["PROPERTIESAPI_URL"] = "https://api.propertiesapi.com"

    @provider = Provider::Propertiesapi.new("test_api_key")
    @provider.stubs(:throttle_request)
  end

  teardown do
    ENV["PROPERTIESAPI_URL"] = @previous_propertiesapi_url
  end

  # Trimmed to the fields this provider reads, plus the listing price, which
  # it must never use as a value.
  def property_response_body(overrides = {})
    {
      "data" => {
        "zpid" => "15073305",
        "address" => ADDRESS,
        "city" => "San Francisco",
        "state" => "CA",
        "zipcode" => "94115",
        "price" => 2650,
        "currency" => "USD",
        "homeStatus" => "FOR_RENT",
        "homeType" => "SINGLE_FAMILY",
        "livingArea" => 1840,
        "yearBuilt" => 1998,
        "zestimate" => 512_000,
        "rentZestimate" => 2650
      }.merge(overrides),
      "meta" => { "credits" => 1, "cached" => false }
    }.to_json
  end

  def stub_lookup(status: 200, body: property_response_body)
    stub_request(:get, PROPERTY_URL)
      .with(query: { "address" => ADDRESS })
      .to_return(status: status, body: body)
  end

  def fetch
    @provider.fetch_property_valuation(
      line1: "2640 Steiner St",
      locality: "San Francisco",
      region: "CA",
      postal_code: "94115"
    )
  end

  test "fetches the Zestimate and property attributes in a single request" do
    stub = stub_request(:get, PROPERTY_URL)
      .with(
        query: { "address" => ADDRESS },
        headers: { "X-Api-Key" => "test_api_key" }
      )
      .to_return(status: 200, body: property_response_body)

    response = fetch

    assert response.success?
    data = response.data
    assert_equal 512_000, data.valuation
    assert_equal "USD", data.currency
    assert_equal "single_family_home", data.property_type
    assert_equal 1998, data.year_built
    assert_equal 1840, data.area_value
    assert_equal "sqft", data.area_unit
    assert_requested stub, times: 1
  end

  test "maps home types and leaves unknown ones unset" do
    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: "100") do
      stub_lookup(body: property_response_body("homeType" => "CONDO"))
      assert_equal "condominium", fetch.data.property_type

      stub_lookup(body: property_response_body("homeType" => "MANUFACTURED"))
      assert_nil fetch.data.property_type
    end
  end

  test "returns an error instead of the listing price when Zillow shows no Zestimate" do
    stub_lookup(body: property_response_body("zestimate" => nil))

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.propertiesapi.errors.no_valuation"), response.error.message
  end

  test "refuses a home whose ZIP code contradicts the entered one" do
    stub_lookup(body: property_response_body("zipcode" => "94123"))

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.propertiesapi.errors.location_mismatch"), response.error.message
  end

  test "maps not found, ambiguous address and unauthorized responses" do
    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: "100") do
      {
        404 => "providers.propertiesapi.errors.not_found",
        409 => "providers.propertiesapi.errors.ambiguous_address",
        401 => "providers.propertiesapi.errors.unauthorized"
      }.each do |status, key|
        stub_lookup(status: status, body: { "error" => { "code" => "x", "message" => "x" } }.to_json)

        response = fetch

        assert_not response.success?, "expected #{status} to fail"
        assert_instance_of Provider::Propertiesapi::Error, response.error
        assert_equal I18n.t(key), response.error.message
      end
    end
  end

  test "maps each documented 402 error code to its own message" do
    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: "100") do
      {
        "credits_exhausted" => [ "providers.propertiesapi.errors.no_credits", { "upgrade_url" => "https://propertiesapi.com/pricing" } ],
        "spend_limit_reached" => [ "providers.propertiesapi.errors.spend_limit_reached", { "dashboard_url" => "https://propertiesapi.com/dashboard" } ],
        "payment_disputed" => [ "providers.propertiesapi.errors.payment_disputed", { "dashboard_url" => "https://propertiesapi.com/dashboard" } ],
        "something_new" => [ "providers.propertiesapi.errors.payment_required", {} ]
      }.each do |code, (key, details)|
        body = { "error" => { "code" => code, "message" => "x", "details" => details }, "meta" => {} }.to_json
        stub_lookup(status: 402, body: body)

        response = fetch

        assert_not response.success?, "expected #{code} to fail"
        assert_instance_of Provider::Propertiesapi::Error, response.error
        assert_equal I18n.t(key), response.error.message
      end
    end
  end

  test "maps a 402 without a JSON error body to the generic billing message" do
    stub_lookup(status: 402, body: "Payment Required")

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.propertiesapi.errors.payment_required"), response.error.message
  end

  test "maps 429 responses to a rate limit error so refreshes stop for the run" do
    stub_lookup(status: 429, body: { "error" => { "code" => "rate_limited", "message" => "Too many requests" } }.to_json)

    response = fetch

    assert_not response.success?
    assert_instance_of Provider::Propertiesapi::RateLimitError, response.error
    assert_requested :get, PROPERTY_URL, query: { "address" => ADDRESS }, times: 1
  end

  test "does not retry a lookup that timed out waiting for the response" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    stub_request(:get, PROPERTY_URL).with(query: { "address" => ADDRESS }).to_raise(Net::ReadTimeout)

    response = fetch

    assert_not response.success?
    assert_requested :get, PROPERTY_URL, query: { "address" => ADDRESS }, times: 1
  end

  test "retries a refused connection and counts both attempts against the cap" do
    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: "100") do
      Faraday::Retry::Middleware.any_instance.stubs(:sleep)
      stub_request(:get, PROPERTY_URL)
        .with(query: { "address" => ADDRESS })
        .to_raise(Faraday::ConnectionFailed.new("connection refused")).then
        .to_return(status: 200, body: property_response_body)

      response = fetch

      assert response.success?
      assert_equal 512_000, response.data.valuation
      assert_requested :get, PROPERTY_URL, query: { "address" => ADDRESS }, times: 2
      assert_equal 2, ProviderRequestCount.count_for("propertiesapi")
    end
  end

  test "does not send a retry that would exceed the monthly limit" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    ProviderRequestCount.create!(provider_key: "propertiesapi", period: ProviderRequestCount.current_period, count: Provider::Propertiesapi::MAX_REQUESTS_PER_MONTH - 1)
    stub_request(:get, PROPERTY_URL)
      .with(query: { "address" => ADDRESS })
      .to_raise(Faraday::ConnectionFailed.new("connection reset"))

    response = with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: nil) { fetch }

    assert_not response.success?
    assert_instance_of Provider::Propertiesapi::RateLimitError, response.error
    assert_requested :get, PROPERTY_URL, query: { "address" => ADDRESS }, times: 1
    assert_equal Provider::Propertiesapi::MAX_REQUESTS_PER_MONTH, ProviderRequestCount.count_for("propertiesapi")
  end

  test "keeps the read timeout under a 60 second reverse proxy read timeout" do
    client = @provider.send(:client)

    assert_operator client.options.timeout, :<, 60
    assert_equal Provider::Propertiesapi::READ_TIMEOUT, client.options.timeout
  end

  test "counts requests against the monthly budget" do
    stub_lookup

    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: nil) do
      assert @provider.requests_remaining?

      fetch
    end

    assert_equal 1, ProviderRequestCount.count_for("propertiesapi")
  end

  test "monthly limit can be changed via ENV override" do
    ProviderRequestCount.create!(provider_key: "propertiesapi", period: ProviderRequestCount.current_period, count: Provider::Propertiesapi::MAX_REQUESTS_PER_MONTH)

    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: "100") do
      assert @provider.requests_remaining?
    end
  end

  test "stops issuing requests once the monthly limit is reached" do
    ProviderRequestCount.create!(provider_key: "propertiesapi", period: ProviderRequestCount.current_period, count: Provider::Propertiesapi::MAX_REQUESTS_PER_MONTH)

    with_env_overrides(PROPERTIESAPI_MAX_REQUESTS_PER_MONTH: nil) do
      assert_not @provider.requests_remaining?

      response = fetch

      assert_not response.success?
      assert_instance_of Provider::Propertiesapi::RateLimitError, response.error
    end
    assert_not_requested :get, %r{api\.propertiesapi\.com}
  end

  test "covers complete US addresses and refreshes at most daily" do
    address = { line1: "2640 Steiner St", locality: "San Francisco", region: "CA", postal_code: "94115" }

    assert Provider::Propertiesapi.lookup_ready?(address)
    assert Provider::Propertiesapi.lookup_ready?(address.merge(country: "United States"))
    assert_not Provider::Propertiesapi.lookup_ready?(address.merge(postal_code: ""))
    assert_not Provider::Propertiesapi.lookup_ready?(address.merge(country: "GB"))
    assert_equal "USD", Provider::Propertiesapi.valuation_currency
    assert_equal 1.day, Provider::Propertiesapi.refresh_interval
  end

  test "is registered as a property valuation provider only when a key is set" do
    assert_includes Provider::Registry.for_concept(:property_valuations).provider_keys, :propertiesapi

    Setting.stubs(:propertiesapi_api_key).returns(nil)
    with_env_overrides(PROPERTIESAPI_API_KEY: nil) do
      assert_nil Provider::Registry.get_provider(:propertiesapi)
    end

    with_env_overrides(PROPERTIESAPI_API_KEY: "env_key") do
      assert_instance_of Provider::Propertiesapi, Provider::Registry.get_provider(:propertiesapi)
    end
  end
end
