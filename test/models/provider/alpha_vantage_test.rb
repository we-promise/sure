require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  # The test environment caches in a null store, so the usage readers need a real
  # RedisCacheStore to notice a counter they cannot read back. The per-run namespace
  # keeps runs sharing one Redis from reading each other's counts.
  test "usage reports the request counter on a real Redis cache" do
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:alpha_vantage:#{SecureRandom.hex(8)}"
    )
    Rails.stubs(:cache).returns(store)

    provider = Provider::AlphaVantage.new("test_api_key")
    provider.define_singleton_method(:sleep) { |_duration| }
    2.times { provider.send(:throttle_request) }

    assert_equal 2, provider.usage.data.used
  ensure
    store&.delete("alpha_vantage:daily:#{Date.current}")
  end
end
