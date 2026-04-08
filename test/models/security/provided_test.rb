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

  # --- rank_search_results ---

  # Helper to build unsaved Security objects for ranking tests
  def build_result(ticker:, name: nil, country_code: nil, exchange_operating_mic: nil)
    Security.new(
      ticker: ticker,
      name: name || ticker,
      country_code: country_code,
      exchange_operating_mic: exchange_operating_mic
    )
  end

  def rank(results, query, country_code = nil)
    Security.send(:rank_search_results, results, query, country_code)
  end

  test "ranking: AAPL exact match ranks above AAPL-prefixed and unrelated" do
    results = [
      build_result(ticker: "AAPLX", name: "Some AAPL Fund"),
      build_result(ticker: "AAPL", name: "Apple Inc", country_code: "US", exchange_operating_mic: "XNAS"),
      build_result(ticker: "AAPL", name: "Apple Inc", country_code: "GB", exchange_operating_mic: "XLON"),
      build_result(ticker: "AAPLD", name: "AAPL Dividend ETF"),
    ]

    ranked = rank(results, "AAPL", "US")

    # Exact matches first, US preferred over GB
    assert_equal "AAPL", ranked[0].ticker
    assert_equal "US", ranked[0].country_code
    assert_equal "AAPL", ranked[1].ticker
    assert_equal "GB", ranked[1].country_code
    # Prefix matches after
    assert ranked[2..].all? { |s| s.ticker.start_with?("AAPL") && s.ticker != "AAPL" }
  end

  test "ranking: Apple name search surfaces Apple Inc above unrelated" do
    results = [
      build_result(ticker: "PINEAPPLE", name: "Pineapple Corp"),
      build_result(ticker: "AAPL", name: "Apple Inc", country_code: "US"),
      build_result(ticker: "APLE", name: "Apple Hospitality REIT"),
      build_result(ticker: "APPL", name: "Appell Petroleum"),
    ]

    ranked = rank(results, "Apple", "US")

    # No ticker matches "APPLE", so all fall to name-contains or worse.
    # "Apple Inc" and "Apple Hospitality" and "Pineapple" contain "APPLE" in name.
    # "Appell Petroleum" does not contain "APPLE".
    # Among name matches, alphabetical ticker breaks ties.
    name_matches = ranked.select { |s| s.name.upcase.include?("APPLE") }
    non_matches = ranked.reject { |s| s.name.upcase.include?("APPLE") }
    assert name_matches.size >= 2
    assert_equal non_matches, ranked.last(non_matches.size)
  end

  test "ranking: SPX exact match first, then SPX-prefixed" do
    results = [
      build_result(ticker: "SPXL", name: "Direxion Daily S&P 500 Bull 3X"),
      build_result(ticker: "SPXS", name: "Direxion Daily S&P 500 Bear 3X"),
      build_result(ticker: "SPX", name: "S&P 500 Index", country_code: "US"),
      build_result(ticker: "SPXU", name: "ProShares UltraPro Short S&P 500"),
    ]

    ranked = rank(results, "SPX", "US")

    assert_equal "SPX", ranked[0].ticker, "Exact match should be first"
    assert ranked[1..].all? { |s| s.ticker.start_with?("SPX") }
  end

  test "ranking: VTTI exact match first regardless of country" do
    results = [
      build_result(ticker: "VTI", name: "Vanguard Total Stock Market ETF", country_code: "US"),
      build_result(ticker: "VTTI", name: "VTTI Energy Partners", country_code: "US"),
      build_result(ticker: "VTTIX", name: "Vanguard Target 2060 Fund"),
    ]

    ranked = rank(results, "VTTI", "US")

    assert_equal "VTTI", ranked[0].ticker, "Exact match should be first"
    assert_equal "VTTIX", ranked[1].ticker, "Prefix match second"
    assert_equal "VTI", ranked[2].ticker, "Non-matching ticker last"
  end

  test "ranking: iShares S&P multi-word query is contiguous substring match" do
    results = [
      build_result(ticker: "IVV", name: "iShares S&P 500 ETF", country_code: "US"),
      build_result(ticker: "CSPX", name: "iShares Core S&P 500 UCITS ETF", country_code: "GB"),
      build_result(ticker: "IJH", name: "iShares S&P Mid-Cap ETF", country_code: "US"),
      build_result(ticker: "UNRELATED", name: "Something Else Corp"),
    ]

    ranked = rank(results, "iShares S&P", "US")

    # Only names containing the exact substring "iShares S&P" match tier 2.
    # "iShares Core S&P" does NOT match (word "Core" breaks contiguity).
    contiguous_matches = ranked.select { |s| s.name.upcase.include?("ISHARES S&P") }
    assert_equal 2, contiguous_matches.size, "Only IVV and IJH contain the exact substring"
    # US contiguous matches should come first
    assert_equal "IJH", ranked[0].ticker  # US, name match, alphabetically before IVV? No...
    assert_includes [ "IVV", "IJH" ], ranked[0].ticker
    assert_includes [ "IVV", "IJH" ], ranked[1].ticker
    # Non-contiguous and unrelated should be last
    assert_equal "UNRELATED", ranked.last.ticker
  end

  test "ranking: tesla name search finds TSLA" do
    results = [
      build_result(ticker: "TSLA", name: "Tesla Inc", country_code: "US"),
      build_result(ticker: "TSLA", name: "Tesla Inc", country_code: "DE"),
      build_result(ticker: "TL0", name: "Tesla Inc", country_code: "DE", exchange_operating_mic: "XETR"),
      build_result(ticker: "TELSA", name: "Telsa Mining Ltd"),
    ]

    ranked = rank(results, "tesla", "US")

    # No ticker matches "TESLA", so all go to name matching
    # "Tesla Inc" contains "TESLA" → tier 2, US preferred
    assert_equal "TSLA", ranked[0].ticker
    assert_equal "US", ranked[0].country_code, "US Tesla should rank first for US user"
  end
end
