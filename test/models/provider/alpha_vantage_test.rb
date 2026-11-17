require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  # The counter is written with `increment`, which stores a raw integer on Redis,
  # so it can only be read back on a real RedisCacheStore; the test env's null
  # store and a MemoryStore both hide a plain `read` returning nil.
  test "usage reports the daily request count on a real Redis cache" do
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:alpha_vantage:#{SecureRandom.hex(8)}"
    )
    travel_to Time.zone.local(2026, 8, 21, 12) do
      Rails.stubs(:cache).returns(store)
      provider = Provider::AlphaVantage.new("test_api_key")
      provider.stubs(:sleep)

      provider.send(:throttle_request)
      provider.send(:throttle_request)

      assert_equal 2, provider.usage.data.used
    end
  ensure
    store&.clear
  end
end
