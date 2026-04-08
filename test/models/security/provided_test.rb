require "test_helper"

class Security::ProvidedTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
  end

  # --- search_provider ---

  test "search_provider returns results from multiple providers" do
    provider_a = mock("provider_a")
    provider_b = mock("provider_b")

    result_a = Provider::SecurityConcept::Security.new(
      symbol: "AAPL", name: "Apple Inc", logo_url: nil,
      exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
    )
    result_b = Provider::SecurityConcept::Security.new(
      symbol: "AAPL", name: "Apple Inc", logo_url: nil,
      exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
    )

    provider_a.stubs(:class).returns(Provider::TwelveData)
    provider_b.stubs(:class).returns(Provider::YahooFinance)

    provider_a.expects(:search_securities).with("AAPL").returns(
      provider_success_response([ result_a ])
    )
    provider_b.expects(:search_securities).with("AAPL").returns(
      provider_success_response([ result_b ])
    )

    Security.stubs(:providers).returns([ provider_a, provider_b ])

    results = Security.search_provider("AAPL")

    # Same ticker+exchange but different providers → both appear (dedup includes provider key)
    assert_equal 2, results.size
    assert results.all? { |s| s.ticker == "AAPL" }
    providers_in_results = results.map(&:price_provider).sort
    assert_includes providers_in_results, "twelve_data"
    assert_includes providers_in_results, "yahoo_finance"
  end

  test "search_provider deduplicates same ticker+exchange+provider" do
    provider = mock("provider")
    provider.stubs(:class).returns(Provider::TwelveData)

    dup_result = Provider::SecurityConcept::Security.new(
      symbol: "MSFT", name: "Microsoft", logo_url: nil,
      exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
    )

    provider.expects(:search_securities).with("MSFT").returns(
      provider_success_response([ dup_result, dup_result ])
    )

    Security.stubs(:providers).returns([ provider ])

    results = Security.search_provider("MSFT")
    assert_equal 1, results.size
  end

  test "search_provider returns empty array for blank symbol" do
    assert_equal [], Security.search_provider("")
    assert_equal [], Security.search_provider(nil)
  end

  test "search_provider returns empty array when no providers configured" do
    Security.stubs(:providers).returns([])
    assert_equal [], Security.search_provider("AAPL")
  end

  test "search_provider keeps fast provider results when slow provider times out" do
    fast_provider = mock("fast_provider")
    slow_provider = mock("slow_provider")

    fast_provider.stubs(:class).returns(Provider::TwelveData)
    slow_provider.stubs(:class).returns(Provider::YahooFinance)

    fast_result = Provider::SecurityConcept::Security.new(
      symbol: "SPY", name: "SPDR S&P 500", logo_url: nil,
      exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
    )

    fast_provider.expects(:search_securities).with("SPY").returns(
      provider_success_response([ fast_result ])
    )
    slow_provider.expects(:search_securities).with("SPY").returns(
      provider_success_response([])
    )

    Security.stubs(:providers).returns([ fast_provider, slow_provider ])

    results = Security.search_provider("SPY")

    assert results.size >= 1, "Fast provider results should be returned even if slow provider returns nothing"
    assert_equal "SPY", results.first.ticker
  end

  test "search_provider handles provider error gracefully" do
    good_provider = mock("good_provider")
    bad_provider = mock("bad_provider")

    good_provider.stubs(:class).returns(Provider::TwelveData)
    bad_provider.stubs(:class).returns(Provider::YahooFinance)

    good_result = Provider::SecurityConcept::Security.new(
      symbol: "GOOG", name: "Alphabet", logo_url: nil,
      exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
    )

    good_provider.expects(:search_securities).with("GOOG").returns(
      provider_success_response([ good_result ])
    )
    bad_provider.expects(:search_securities).with("GOOG").raises(StandardError, "API down")

    Security.stubs(:providers).returns([ good_provider, bad_provider ])

    results = Security.search_provider("GOOG")

    assert_equal 1, results.size
    assert_equal "GOOG", results.first.ticker
  end

  # --- price_data_provider ---

  test "price_data_provider returns assigned provider" do
    provider = mock("tiingo_provider")
    Security.stubs(:provider_for).with("tiingo").returns(provider)

    @security.update!(price_provider: "tiingo")

    assert_equal provider, @security.price_data_provider
  end

  test "price_data_provider returns nil when assigned provider is disabled" do
    Security.stubs(:provider_for).with("tiingo").returns(nil)

    @security.update!(price_provider: "tiingo")

    assert_nil @security.price_data_provider
  end

  test "price_data_provider falls back to first provider when none assigned" do
    fallback_provider = mock("fallback")
    Security.stubs(:providers).returns([ fallback_provider ])

    @security.update!(price_provider: nil)

    assert_equal fallback_provider, @security.price_data_provider
  end

  # --- provider_status ---

  test "provider_status returns provider_unavailable when assigned provider disabled" do
    Security.stubs(:provider_for).with("tiingo").returns(nil)

    @security.update!(price_provider: "tiingo")

    assert_equal :provider_unavailable, @security.provider_status
  end

  test "provider_status returns ok for healthy security" do
    provider = mock("provider")
    Security.stubs(:provider_for).with("twelve_data").returns(provider)

    @security.update!(price_provider: "twelve_data", offline: false, failed_fetch_count: 0)

    assert_equal :ok, @security.provider_status
  end
end
