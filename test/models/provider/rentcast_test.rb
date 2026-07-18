require "test_helper"

class Provider::RentcastTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Rentcast.new("test_api_key")
    @provider.stubs(:throttle_request)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  def avm_response_body
    {
      "price" => 356_000,
      "priceRangeLow" => 330_000,
      "priceRangeHigh" => 382_000,
      "subjectProperty" => {
        "formattedAddress" => "5500 Grand Lake Dr, San Antonio, TX 78244",
        "propertyType" => "Single Family",
        "yearBuilt" => 1973,
        "squareFootage" => 1878
      }
    }.to_json
  end

  test "fetches valuation and property attributes in a single request" do
    stub = stub_request(:get, "https://api.rentcast.io/v1/avm/value")
      .with(
        query: {
          "address" => "5500 Grand Lake Dr, San Antonio, TX, 78244",
          "lookupSubjectAttributes" => "true"
        },
        headers: { "X-Api-Key" => "test_api_key" }
      )
      .to_return(status: 200, body: avm_response_body)

    response = @provider.fetch_property_valuation(
      line1: "5500 Grand Lake Dr",
      locality: "San Antonio",
      region: "TX",
      postal_code: "78244"
    )

    assert response.success?
    data = response.data
    assert_equal 356_000, data.valuation
    assert_equal "USD", data.currency
    assert_equal "single_family_home", data.property_type
    assert_equal 1973, data.year_built
    assert_equal 1878, data.area_value
    assert_equal "sqft", data.area_unit
    assert_requested stub
  end

  test "returns a friendly error when no property matches the address" do
    stub_request(:get, "https://api.rentcast.io/v1/avm/value")
      .with(query: hash_including("address" => "1 Nowhere Ln"))
      .to_return(status: 404, body: { "error" => "Not found" }.to_json)

    response = @provider.fetch_property_valuation(line1: "1 Nowhere Ln")

    assert_not response.success?
    assert_match(/could not find a property/i, response.error.message)
  end

  test "counts requests against the monthly budget" do
    stub_request(:get, "https://api.rentcast.io/v1/avm/value")
      .with(query: hash_including("lookupSubjectAttributes" => "true"))
      .to_return(status: 200, body: avm_response_body)

    assert @provider.requests_remaining?

    @provider.fetch_property_valuation(line1: "5500 Grand Lake Dr")

    count_key = "rentcast:avm_request_count:#{Date.current.strftime('%Y-%m')}"
    assert_equal 1, Rails.cache.read(count_key).to_i
  end

  test "monthly limit can be raised via ENV override" do
    count_key = "rentcast:avm_request_count:#{Date.current.strftime('%Y-%m')}"
    Rails.cache.write(count_key, Provider::Rentcast::MAX_REQUESTS_PER_MONTH)

    ENV["RENTCAST_MAX_REQUESTS_PER_MONTH"] = "100"
    assert @provider.requests_remaining?
  ensure
    ENV.delete("RENTCAST_MAX_REQUESTS_PER_MONTH")
  end

  test "stops issuing requests once the monthly limit is reached" do
    count_key = "rentcast:avm_request_count:#{Date.current.strftime('%Y-%m')}"
    Rails.cache.write(count_key, Provider::Rentcast::MAX_REQUESTS_PER_MONTH)

    assert_not @provider.requests_remaining?

    response = @provider.fetch_property_valuation(line1: "5500 Grand Lake Dr")

    assert_not response.success?
    assert_instance_of Provider::Rentcast::RateLimitError, response.error
    assert_not_requested :get, %r{api\.rentcast\.io}
  end
end
