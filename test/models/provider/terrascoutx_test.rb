require "test_helper"

class Provider::TerrascoutxTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Terrascoutx.new("test_api_key")
    @provider.stubs(:throttle_request)
  end

  # Recorded from the live API for 1000 Main St, Houston (Harris County
  # parcel 0011390000002), trimmed to its address, value and building fields.
  def property_record(overrides = {})
    {
      "id" => "hcad-0011390000002",
      "address" => { "street" => "1000 Main St", "city" => "Houston", "state" => "TX", "zip" => "77002", "county" => "Harris" },
      "parcelId" => "0011390000002",
      "landUse" => "Commercial",
      "landUseCode" => "F1",
      "livingAreaSqft" => 1_181_384,
      "yearBuilt" => 2001,
      "totalAppraised" => 190_756_291,
      "marketValue" => 190_756_291
    }.merge(overrides)
  end

  def suggest_body(*records)
    { "results" => records }.to_json
  end

  def fetch_main_st
    @provider.fetch_property_valuation(line1: "1000 Main St", locality: "Houston", region: "TX", postal_code: "77002")
  end

  test "fetches valuation and property attributes in a single request" do
    stub = stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(
        query: { "q" => "1000 Main St, Houston, TX, 77002", "limit" => "5", "state" => "TX" },
        headers: { "X-Api-Key" => "test_api_key" }
      )
      .to_return(status: 200, body: suggest_body(property_record))

    response = fetch_main_st

    assert response.success?
    data = response.data
    assert_equal 190_756_291, data.valuation
    assert_equal "USD", data.currency
    assert_equal "commercial", data.property_type
    assert_equal 2001, data.year_built
    assert_equal 1_181_384, data.area_value
    assert_equal "sqft", data.area_unit
    assert_requested stub
  end

  test "treats a zero market value as absent and falls back to the total appraised value" do
    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1000 Main St, Houston, TX, 77002"))
      .to_return(status: 200, body: suggest_body(property_record("marketValue" => 0, "totalAppraised" => 180_000_000)))

    response = fetch_main_st

    assert response.success?
    assert_equal 180_000_000, response.data.valuation
  end

  test "returns an error when the record carries no usable value" do
    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1000 Main St, Houston, TX, 77002"))
      .to_return(status: 200, body: suggest_body(property_record("marketValue" => nil, "totalAppraised" => 0)))

    response = fetch_main_st

    assert_not response.success?
    assert_equal I18n.t("providers.terrascoutx.errors.no_valuation"), response.error.message
  end

  test "picks the candidate matching the entered house number and ZIP" do
    neighbour = property_record("id" => "hcad-neighbour", "address" => { "street" => "1001 Main St", "zip" => "77002" }, "marketValue" => 5_000_000)
    other_zip = property_record("id" => "mcad-other", "address" => { "street" => "1000 Main St", "zip" => "77301" }, "marketValue" => 250_000)

    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1000 Main St, Houston, TX, 77002"))
      .to_return(status: 200, body: suggest_body(neighbour, other_zip, property_record))

    response = fetch_main_st

    assert response.success?
    assert_equal 190_756_291, response.data.valuation
  end

  test "rejects a match with a different house number or ZIP" do
    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1000 Main St, Houston, TX, 77002"))
      .to_return(status: 200, body: suggest_body(property_record("address" => { "street" => "1001 Main St", "zip" => "77002" })))

    response = fetch_main_st

    assert_not response.success?
    assert_equal I18n.t("providers.terrascoutx.errors.location_mismatch"), response.error.message
  end

  test "returns a friendly error when no property matches the address" do
    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1 Nowhere Ln"))
      .to_return(status: 200, body: suggest_body)

    response = @provider.fetch_property_valuation(line1: "1 Nowhere Ln")

    assert_not response.success?
    assert_match(/could not find a property/i, response.error.message)
  end

  test "maps land use descriptions to property subtypes" do
    {
      "Residential Single-Family" => "single_family_home",
      "Residential Condominium" => "condominium",
      "Townhome" => "townhouse",
      "Duplex" => "multi_family_home",
      "Apartments" => "apartment",
      "Agricultural" => "agri_land",
      "Commercial" => "commercial",
      "Vacant Land" => "plot",
      "Real Property" => nil
    }.each do |land_use, expected|
      actual = @provider.send(:subtype_for_land_use, land_use)
      if expected.nil?
        assert_nil actual, "expected #{land_use.inspect} to map to nil"
      else
        assert_equal expected, actual, "expected #{land_use.inspect} to map to #{expected.inspect}"
      end
    end
  end

  test "returns a rate limit error when the API reports its monthly limit" do
    stub_request(:get, "https://api.terrascoutx.com/v1/suggest")
      .with(query: hash_including("q" => "1000 Main St, Houston, TX, 77002"))
      .to_return(status: 429, body: { "error" => "monthly_request_limit_exceeded", "limit" => 2000, "used" => 2000, "plan" => "free" }.to_json)

    response = fetch_main_st

    assert_not response.success?
    assert_instance_of Provider::Terrascoutx::RateLimitError, response.error
  end

  test "stops issuing requests once the monthly limit is reached" do
    ProviderRequestCount.create!(provider_key: "terrascoutx", period: ProviderRequestCount.current_period, count: Provider::Terrascoutx::MAX_REQUESTS_PER_MONTH)

    assert_not @provider.requests_remaining?

    response = fetch_main_st

    assert_not response.success?
    assert_instance_of Provider::Terrascoutx::RateLimitError, response.error
    assert_not_requested :get, %r{api\.terrascoutx\.com}
  end
end
