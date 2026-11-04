require "test_helper"

class Provider::DvfTest < ActiveSupport::TestCase
  GEOCODER = "https://data.geopf.fr/geocodage".freeze
  DVF = "https://files.data.gouv.fr/geo-dvf/latest/csv".freeze
  STORAGE = "https://geo-dvf.example-storage.test/latest/csv".freeze
  LAT = 48.8546
  LON = 2.3973
  # 35 m², as the refresh job passes it.
  SQFT = 377

  CSV_HEADER = "id_mutation,date_mutation,nature_mutation,valeur_fonciere,type_local,surface_reelle_bati,lot1_surface_carrez,latitude,longitude".freeze

  setup do
    travel_to Date.new(2026, 6, 15)
    @provider = Provider::Dvf.new

    stub_request(:get, %r{\A#{Regexp.escape(DVF)}/}).to_return(status: 404)
    stub_request(:get, "#{GEOCODER}/search")
      .with(query: hash_including("postcode" => "75020"))
      .to_return(status: 200, body: geocoder_body("75120"))
    stub_request(:get, %r{\A#{Regexp.escape(GEOCODER)}/reverse})
      .to_return(status: 200, body: geocoder_body("75120"))
  end

  def geocoder_body(citycode)
    {
      "features" => [
        { "geometry" => { "coordinates" => [ LON, LAT ] }, "properties" => { "citycode" => citycode } }
      ]
    }.to_json
  end

  def sales_csv(count, price_per_sqm: 9_000)
    rows = (1..count).map do |i|
      "m#{i},2025-#{format("%02d", (i % 12) + 1)}-10,Vente,#{price_per_sqm * 35},Appartement,35,,#{LAT + 0.001},#{LON}"
    end
    ([ CSV_HEADER ] + rows).join("\n")
  end

  # files.data.gouv.fr answers with a redirect to its object storage.
  def stub_sales(csv, year: 2025, commune: "75120")
    stub_request(:get, "#{DVF}/#{year}/communes/75/#{commune}.csv")
      .to_return(status: 302, headers: { "Location" => "#{STORAGE}/#{year}/communes/75/#{commune}.csv" })
    stub_request(:get, "#{STORAGE}/#{year}/communes/75/#{commune}.csv")
      .to_return(status: 200, body: csv)
  end

  def fetch(**overrides)
    @provider.fetch_property_valuation(
      line1: "82 rue Exemple",
      postal_code: "75020",
      square_footage: SQFT,
      property_type: "apartment",
      **overrides
    )
  end

  test "values an apartment from comparable sales, following the storage redirect" do
    stub_sales(sales_csv(15))

    response = fetch

    assert response.success?, response.error&.message
    data = response.data
    assert_equal 315_000, data.valuation
    assert_equal "EUR", data.currency
    assert_equal 315_000, data.valuation_low
    assert_equal 315_000, data.valuation_high
    assert_equal "high", data.confidence
    assert_equal "apartment", data.property_type
    assert_equal 35, data.area_value
    assert_equal "sqm", data.area_unit
  end

  test "reads sales from neighbouring communes too" do
    stub_request(:get, %r{\A#{Regexp.escape(GEOCODER)}/reverse})
      .to_return(status: 200, body: geocoder_body("75111"))
    stub_sales(sales_csv(8))
    stub_sales(sales_csv(8), commune: "75111")

    response = fetch

    assert response.success?, response.error&.message
    assert_equal 315_000, response.data.valuation
  end

  test "rejects property types DVF can't value without a request" do
    response = fetch(property_type: "plot")

    assert_not response.success?
    assert_equal I18n.t("providers.dvf.errors.unsupported_property_type"), response.error.message
    assert_not_requested :get, %r{\A#{Regexp.escape(GEOCODER)}}
  end

  test "requires the living area" do
    response = fetch(square_footage: nil)

    assert_not response.success?
    assert_equal I18n.t("providers.dvf.errors.area_required"), response.error.message
  end

  test "reports an address the geocoder can't find" do
    stub_request(:get, "#{GEOCODER}/search")
      .with(query: hash_including("postcode" => "75020"))
      .to_return(status: 200, body: { "features" => [] }.to_json)

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.dvf.errors.address_not_found"), response.error.message
  end

  test "reports too few comparable sales" do
    stub_sales(sales_csv(10))

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.dvf.errors.not_enough_sales"), response.error.message
  end

  test "reports the open data service being down" do
    stub_request(:get, "#{GEOCODER}/search")
      .with(query: hash_including("postcode" => "75020"))
      .to_return(status: 503)

    response = fetch

    assert_not response.success?
    assert_equal I18n.t("providers.dvf.errors.unavailable"), response.error.message
  end

  test "counts each lookup against the monthly cap" do
    stub_sales(sales_csv(15))

    assert_difference -> { ProviderRequestCount.count_for("dvf") }, 1 do
      fetch
    end
  end

  test "lookups need a French postcode outside Alsace-Moselle and Mayotte, an area and a supported type" do
    address = { line1: "82 rue Exemple", postal_code: "75020", country: "France" }

    assert Provider::Dvf.lookup_ready?(address, area: SQFT, property_type: "apartment")
    assert Provider::Dvf.lookup_ready?(address.merge(country: "FR"), area: SQFT, property_type: "townhouse")
    assert_not Provider::Dvf.lookup_ready?(address, area: nil, property_type: "apartment")
    assert_not Provider::Dvf.lookup_ready?(address, area: SQFT, property_type: "plot")
    assert_not Provider::Dvf.lookup_ready?(address.merge(country: "US"), area: SQFT, property_type: "apartment")
    %w[57000 67000 68100 97600].each do |postal_code|
      assert_not Provider::Dvf.lookup_ready?(address.merge(postal_code: postal_code), area: SQFT, property_type: "apartment"), postal_code
    end
  end

  test "is registered only once enabled" do
    Setting.stubs(:dvf_enabled).returns(false)
    assert_nil Provider::Registry.get_provider(:dvf)

    Setting.stubs(:dvf_enabled).returns(true)
    assert_instance_of Provider::Dvf, Provider::Registry.get_provider(:dvf)
  end
end
