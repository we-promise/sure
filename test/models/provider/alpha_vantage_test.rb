require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  OVERVIEW_URL = "https://www.alphavantage.co/query".freeze

  setup do
    @provider = Provider::AlphaVantage.new("test_api_key")
  end

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

  test "every attempt of a request is counted against the daily limit, including retries" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError).then
      .to_raise(Faraday::TimeoutError).then
      .to_return(status: 200, body: { "Name" => "Apple Inc", "Symbol" => "AAPL" }.to_json)

    assert @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?

    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 3
    assert_equal 3, Rails.cache.read("alpha_vantage:daily:#{Date.current}")
  end

  test "a retry that would exceed the daily limit is refused before reaching Alpha Vantage" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    @provider.stubs(:sleep)
    Faraday::Retry::Middleware.any_instance.stubs(:sleep)
    store.write("alpha_vantage:daily:#{Date.current}", 24)

    stub_request(:get, OVERVIEW_URL)
      .with(query: hash_including("function" => "OVERVIEW"))
      .to_raise(Faraday::TimeoutError)

    result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

    assert_not result.success?
    assert_kind_of Provider::AlphaVantage::RateLimitError, result.error
    # The first attempt is counted (24 -> 25) and reaches the wire; the retry is counted
    # past the limit (25 -> 26) and refused before it
    assert_requested :get, OVERVIEW_URL, query: hash_including("function" => "OVERVIEW"), times: 1
    assert_equal 26, store.read("alpha_vantage:daily:#{Date.current}")
  end
end
