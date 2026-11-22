require "test_helper"

class Geocoding::NominatimClientTest < ActiveSupport::TestCase
  setup do
    @client = Geocoding::NominatimClient.new
    # Test env defaults to :null_store, which never actually caches. Swap in a
    # real store (matches the pattern used elsewhere for Rails.cache.fetch specs)
    # so the "cached" test below can verify a second call doesn't hit the network.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "search returns candidate places for a query" do
    VCR.use_cassette("nominatim/search_malaga") do
      results = @client.search("Malaga, Spain")

      assert_not_empty results
      first = results.first
      assert_in_delta 36.72, first.lat, 0.5
      assert_in_delta(-4.42, first.lng, 0.5)
      # Nominatim returns the Spanish spelling ("Málaga"); match either form.
      assert_match(/m.laga/i, first.display_name)
    end
  end

  test "search returns an empty array for a blank query" do
    assert_equal [], @client.search("")
    assert_equal [], @client.search(nil)
  end

  test "search returns an empty array when nothing matches" do
    VCR.use_cassette("nominatim/search_no_results") do
      results = @client.search("zzzzzznonexistentplacezzzzz")

      assert_equal [], results
    end
  end

  test "reverse returns the display name for coordinates" do
    VCR.use_cassette("nominatim/reverse_41_3851_2_1734") do
      result = @client.reverse(41.3851, 2.1734)

      assert_not_nil result
      assert_match(/barcelona/i, result.display_name)
    end
  end

  test "search results are cached" do
    VCR.use_cassette("nominatim/search_malaga") do
      @client.search("Malaga, Spain")
    end

    # No cassette inserted for this call — if it hits the network, VCR raises.
    results = @client.search("Malaga, Spain")
    assert_not_empty results
  end
end
