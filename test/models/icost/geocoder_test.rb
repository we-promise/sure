require "test_helper"

class Icost::GeocoderTest < ActiveSupport::TestCase
  setup { @cache = ActiveSupport::Cache::MemoryStore.new }

  test "searches only the chosen place name and caches the result" do
    request = stub_request(:get, "https://nominatim.openstreetmap.org/search")
      .with(query: { q: "Synthetic museum", format: "jsonv2", limit: "5" })
      .to_return(body: [ { lat: "51.5", lon: "-0.1", display_name: "Synthetic museum, Test City" } ].to_json)
    geocoder = Icost::Geocoder.new(cache: @cache)
    2.times do
      result = geocoder.search("Synthetic museum")
      assert_equal "Synthetic museum, Test City", result.sole.fetch("name")
    end
    assert_requested request, times: 1
  end

  test "rate limits different queries across users and never caches provider failures" do
    stub_request(:get, /nominatim.openstreetmap.org/).to_return(status: 503)
    assert_raises(Icost::Geocoder::Error) { Icost::Geocoder.new(cache: @cache).search("Synthetic park") }
    assert_raises(Icost::Geocoder::RateLimited) { Icost::Geocoder.new(cache: @cache).search("Synthetic lake") }
  end
end
