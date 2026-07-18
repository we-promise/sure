require "test_helper"

class Provider::RealieTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Realie.new("test_api_key")
    @provider.stubs(:throttle_request)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  def address_lookup_body(overrides = {})
    {
      "property" => {
        "useCode" => "Single Family Residential",
        "yearBuilt" => 1985,
        "buildingArea" => 1500.0,
        "modelValue" => 420_000.0,
        "modelValueMin" => 390_000.0,
        "modelValueMax" => 450_000.0,
        "totalMarketValue" => 400_000
      }.merge(overrides)
    }.to_json
  end

  test "fetches valuation and property attributes in a single request" do
    stub = stub_request(:get, "https://app.realie.ai/api/public/property/address/")
      .with(
        query: { "address" => "123 Main Street", "state" => "CA" },
        headers: { "Authorization" => "test_api_key" }
      )
      .to_return(status: 200, body: address_lookup_body)

    response = @provider.fetch_property_valuation(
      line1: "123 Main Street",
      locality: "Los Angeles",
      region: "CA",
      postal_code: "90001"
    )

    assert response.success?
    data = response.data
    assert_equal 420_000, data.valuation
    assert_equal "USD", data.currency
    assert_equal "single_family_home", data.property_type
    assert_equal 1985, data.year_built
    assert_equal 1500, data.area_value
    assert_equal "sqft", data.area_unit
    assert_requested stub
  end

  test "falls back to the assessed market value when no model value is present" do
    stub_request(:get, "https://app.realie.ai/api/public/property/address/")
      .with(query: hash_including("address" => "123 Main Street"))
      .to_return(status: 200, body: address_lookup_body("modelValue" => nil))

    response = @provider.fetch_property_valuation(line1: "123 Main Street", region: "CA")

    assert response.success?
    assert_equal 400_000, response.data.valuation
  end

  test "returns a friendly error when no property matches the address" do
    stub_request(:get, "https://app.realie.ai/api/public/property/address/")
      .with(query: hash_including("address" => "1 Nowhere Ln"))
      .to_return(status: 404, body: { "detail" => "Not found" }.to_json)

    response = @provider.fetch_property_valuation(line1: "1 Nowhere Ln", region: "CA")

    assert_not response.success?
    assert_match(/could not find a property/i, response.error.message)
  end

  test "maps use codes to property subtypes by keyword" do
    {
      "Single Family Residential" => "single_family_home",
      "Duplex (2 units)" => "multi_family_home",
      "Residential Condominium" => "condominium",
      "Townhouse" => "townhouse",
      "Vacant Land" => "plot",
      "Commercial Office" => "commercial",
      "Agricultural" => "agri_land",
      "Something Unrecognized" => nil
    }.each do |use_code, expected|
      actual = @provider.send(:subtype_for_use_code, use_code)
      if expected.nil?
        assert_nil actual, "expected #{use_code.inspect} to map to nil"
      else
        assert_equal expected, actual, "expected #{use_code.inspect} to map to #{expected.inspect}"
      end
    end
  end

  test "stops issuing requests once the monthly limit is reached" do
    count_key = "realie:avm_request_count:#{Date.current.strftime('%Y-%m')}"
    Rails.cache.write(count_key, Provider::Realie::MAX_REQUESTS_PER_MONTH)

    assert_not @provider.requests_remaining?

    response = @provider.fetch_property_valuation(line1: "123 Main Street", region: "CA")

    assert_not response.success?
    assert_instance_of Provider::Realie::RateLimitError, response.error
    assert_not_requested :get, %r{app\.realie\.ai}
  end
end
