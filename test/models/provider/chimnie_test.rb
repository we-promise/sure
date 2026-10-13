require "test_helper"

class Provider::ChimnieTest < ActiveSupport::TestCase
  VALUATION_URL = "https://api.chimnie.com/residential/uprn/999000000001".freeze

  setup do
    @provider = Provider::Chimnie.new("test_api_key")
    @provider.stubs(:throttle_request)
  end

  def valuation_response_body(sale = nil)
    {
      "property" => {
        "value" => {
          "sale" => sale || {
            "property_value" => 425_000,
            "property_value_range" => [ 340_000, 530_000 ],
            "property_value_confidence" => "high"
          }
        }
      },
      "id" => "999000000001"
    }.to_json
  end

  def stub_valuation(status: 200, body: valuation_response_body)
    stub_request(:get, VALUATION_URL)
      .with(query: { "fields" => Provider::Chimnie::FREE_VALUATION_FIELDS.join(",") })
      .to_return(status: status, body: body)
  end

  test "fetches a free valuation by UPRN with only the free fields" do
    stub = stub_request(:get, VALUATION_URL)
      .with(
        query: {
          "fields" => "property.value.sale.property_value,property.value.sale.property_value_range,property.value.sale.property_value_confidence"
        },
        headers: { "Authorization" => "Bearer test_api_key" }
      )
      .to_return(status: 200, body: valuation_response_body)

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert response.success?
    data = response.data
    assert_equal 425_000, data.valuation
    assert_equal "GBP", data.currency
    assert_equal 340_000, data.valuation_low
    assert_equal 530_000, data.valuation_high
    assert_equal "high", data.confidence
    assert_equal "999000000001", data.external_id
    assert_nil data.property_type
    assert_nil data.year_built
    assert_nil data.area_value
    assert_requested stub
  end

  test "normalizes spaces in the UPRN and confidence casing" do
    stub_valuation(body: valuation_response_body(
      "property_value" => 425_000,
      "property_value_range" => [ 340_000, 530_000 ],
      "property_value_confidence" => "Medium"
    ))

    response = @provider.fetch_property_valuation(external_id: " 9990 0000 0001 ")

    assert response.success?
    assert_equal "medium", response.data.confidence
  end

  test "tolerates a missing range and confidence" do
    stub_valuation(body: valuation_response_body("property_value" => 425_000))

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert response.success?
    assert_nil response.data.valuation_low
    assert_nil response.data.valuation_high
    assert_nil response.data.confidence
  end

  test "returns an error when the estimate is null" do
    stub_valuation(body: valuation_response_body("property_value" => nil))

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert_not response.success?
    assert_match(/does not have a value estimate/i, response.error.message)
  end

  test "rejects a missing or malformed UPRN without spending a request" do
    [ nil, "", "ABC123", "1234567890123" ].each do |uprn|
      response = @provider.fetch_property_valuation(external_id: uprn)

      assert_not response.success?
      assert_match(/UPRN/, response.error.message)
    end

    assert_equal 0, ProviderRequestCount.count_for("chimnie")
    assert_not_requested :get, %r{api\.chimnie\.com}
  end

  test "maps not found, commercial, unauthorized and insufficient balance responses" do
    {
      404 => /could not find a property/i,
      409 => /only values residential properties/i,
      401 => /rejected the API key/i,
      402 => /balance is too low/i
    }.each do |status, message|
      stub_valuation(status: status, body: { "statusCode" => status }.to_json)

      response = @provider.fetch_property_valuation(external_id: "999000000001")

      assert_not response.success?, "expected #{status} to fail"
      assert_instance_of Provider::Chimnie::Error, response.error
      assert_match message, response.error.message
    end
  end

  test "retries 429 responses, since the per-key limit is shared across processes" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    stub_request(:get, VALUATION_URL)
      .with(query: hash_including("fields"))
      .to_return({ status: 429, body: { "statusCode" => 429 }.to_json }, { status: 200, body: valuation_response_body })

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert response.success?
    assert_equal 425_000, response.data.valuation
    assert_requested :get, VALUATION_URL, query: hash_including("fields"), times: 2
    assert_equal 2, ProviderRequestCount.count_for("chimnie")
  end

  test "maps persistent 429 responses to a rate limit error" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    stub_valuation(status: 429, body: { "statusCode" => 429, "message" => "Rate limit exceeded" }.to_json)

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert_not response.success?
    assert_instance_of Provider::Chimnie::RateLimitError, response.error
    assert_requested :get, VALUATION_URL, query: hash_including("fields"), times: 4
    assert_equal 4, ProviderRequestCount.count_for("chimnie")
  end

  test "throttles every attempt, including retries" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    stub_request(:get, VALUATION_URL)
      .with(query: hash_including("fields"))
      .to_return({ status: 429, body: { "statusCode" => 429 }.to_json }, { status: 200, body: valuation_response_body })

    @provider.expects(:throttle_request).twice

    assert @provider.fetch_property_valuation(external_id: "999000000001").success?
  end

  test "stops retrying once the monthly limit is reached" do
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    ProviderRequestCount.create!(provider_key: "chimnie", period: ProviderRequestCount.current_period, count: Provider::Chimnie::MAX_REQUESTS_PER_MONTH - 1)
    stub_valuation(status: 429, body: { "statusCode" => 429 }.to_json)

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert_instance_of Provider::Chimnie::RateLimitError, response.error
    assert_match(/monthly request limit/, response.error.message)
    assert_requested :get, VALUATION_URL, query: hash_including("fields"), times: 1
  end

  test "counts requests against the monthly budget" do
    stub_valuation

    @provider.fetch_property_valuation(external_id: "999000000001")

    assert_equal 1, ProviderRequestCount.count_for("chimnie")
  end

  test "monthly limit can be changed via ENV override" do
    ProviderRequestCount.create!(provider_key: "chimnie", period: ProviderRequestCount.current_period, count: Provider::Chimnie::MAX_REQUESTS_PER_MONTH)

    ENV["CHIMNIE_MAX_REQUESTS_PER_MONTH"] = "2000"
    assert @provider.requests_remaining?
  ensure
    ENV.delete("CHIMNIE_MAX_REQUESTS_PER_MONTH")
  end

  test "stops issuing requests once the monthly limit is reached" do
    ProviderRequestCount.create!(provider_key: "chimnie", period: ProviderRequestCount.current_period, count: Provider::Chimnie::MAX_REQUESTS_PER_MONTH)

    response = @provider.fetch_property_valuation(external_id: "999000000001")

    assert_not response.success?
    assert_instance_of Provider::Chimnie::RateLimitError, response.error
    assert_not_requested :get, %r{api\.chimnie\.com}
  end

  test "describes UK coverage and a monthly refresh interval" do
    assert_equal "GBP", @provider.valuation_currency
    assert_equal "GB", Provider::Chimnie.supported_country
    assert Provider::Chimnie.requires_external_id?
    assert_equal 1.month, Provider::Chimnie.refresh_interval
  end

  test "is ready to look up UK addresses with a UPRN" do
    address = { line1: "1 High Street", postal_code: "CH1 1MN", country: "GB" }

    assert Provider::Chimnie.lookup_ready?(address, "999000000001")
    assert Provider::Chimnie.lookup_ready?(address.merge(country: "UK"), "999000000001")
    assert_not Provider::Chimnie.lookup_ready?(address, nil)
    assert_not Provider::Chimnie.lookup_ready?(address.merge(country: "US"), "999000000001")
    assert_not Provider::Chimnie.lookup_ready?(address.merge(postal_code: ""), "999000000001")
  end

  test "existing US providers keep requiring a complete US address" do
    address = { line1: "123 Main Street", locality: "Los Angeles", region: "CA", postal_code: "90001", country: "US" }

    assert Provider::Rentcast.lookup_ready?(address)
    assert Provider::Realie.lookup_ready?(address.merge(country: ""))
    assert_not Provider::Rentcast.lookup_ready?(address.merge(region: ""))
    assert_not Provider::Rentcast.lookup_ready?(address.merge(country: "GB"))
    assert_equal "USD", Provider::Rentcast.new("key").valuation_currency
  end
end
