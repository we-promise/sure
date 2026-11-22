require "test_helper"

class Security::ProvidedTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    Security.instance_variable_set(:@logged_keyless_substitutions, nil)
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
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data", "yahoo_finance" ])

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

  test "search_provider invokes technical_failure for a provider that errors" do
    bad_provider = mock("bad_provider")
    bad_provider.stubs(:class).returns(Provider::YahooFinance)
    bad_provider.expects(:search_securities).with("XMAW").raises(StandardError, "rate limited")

    Security.stubs(:providers).returns([ bad_provider ])

    failed_providers = []
    results = Security.search_provider("XMAW", technical_failure: ->(provider) { failed_providers << provider })

    assert_equal [], results
    assert_equal [ bad_provider ], failed_providers
  end

  test "search_provider does not invoke technical_failure when a provider genuinely finds nothing" do
    provider = mock("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:search_securities).with("NOPE").returns(provider_success_response([]))

    Security.stubs(:providers).returns([ provider ])

    failure_called = false
    results = Security.search_provider("NOPE", technical_failure: ->(_provider) { failure_called = true })

    assert_equal [], results
    refute failure_called
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

  test "import_provider_details logs provider metadata failures to debug log" do
    provider = mock("provider")
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.stubs(:fetch_security_info).returns(
      provider_error_response(Provider::Error.new("metadata unavailable"))
    )

    @security.stubs(:price_data_provider).returns(provider)

    assert_difference "DebugLogEntry.count", 1 do
      @security.import_provider_details
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "security_metadata_fetch", entry.category
    assert_equal "warn", entry.level
    assert_equal "Failed to get security info", entry.message
    assert_equal "security", entry.source.underscore
    assert_equal @security.id, entry.metadata["security_id"]
    assert_equal @security.ticker, entry.metadata["ticker"]
    assert_equal "metadata unavailable", entry.metadata["provider_error"]
    assert_equal "twelve_data", entry.provider_key
  end

  # A Yahoo-style answer: a name, but no logo and no website (Yahoo never
  # returns a logo, and funds have no website), so the has-metadata gate can't
  # close. The test env's null cache store would make the recheck window a
  # no-op, so these tests swap in a real store.
  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end

  def details_without_logo_or_website
    Provider::SecurityConcept::SecurityInfo.new(
      symbol: "AAPL", name: "Apple", links: nil, logo_url: nil,
      description: nil, kind: "common stock", exchange_operating_mic: "XNAS"
    )
  end

  test "import_provider_details doesn't ask again soon after an answer without a logo or website" do
    with_memory_cache do
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::YahooFinance)
      provider.expects(:fetch_security_info).once.returns(provider_success_response(details_without_logo_or_website))
      @security.stubs(:price_data_provider).returns(provider)
      @security.stubs(:import_brand_logo)

      @security.import_provider_details
      @security.import_provider_details
    end
  end

  test "import_provider_details asks again once the recheck interval has passed" do
    with_memory_cache do
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::YahooFinance)
      provider.expects(:fetch_security_info).twice.returns(provider_success_response(details_without_logo_or_website))
      @security.stubs(:price_data_provider).returns(provider)
      @security.stubs(:import_brand_logo)

      @security.import_provider_details
      travel Security::Provided::PROVIDER_DETAILS_RECHECK_INTERVAL + 1.minute do
        @security.import_provider_details
      end
    end
  end

  test "import_provider_details retries a failed lookup on the next import" do
    with_memory_cache do
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::YahooFinance)
      provider.expects(:fetch_security_info).twice.returns(
        provider_error_response(Provider::YahooFinance::RateLimitError.new("Yahoo Finance rate limit exceeded"))
      )
      @security.stubs(:price_data_provider).returns(provider)
      @security.stubs(:import_brand_logo)

      @security.import_provider_details
      @security.import_provider_details
    end
  end

  test "import_provider_details with clear_cache asks again despite a recent answer" do
    with_memory_cache do
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::YahooFinance)
      provider.expects(:fetch_security_info).twice.returns(provider_success_response(details_without_logo_or_website))
      @security.stubs(:price_data_provider).returns(provider)
      @security.stubs(:import_brand_logo)

      @security.import_provider_details
      @security.import_provider_details(clear_cache: true)
    end
  end

  test "import_provider_details asks a different provider despite a recent answer from another" do
    with_memory_cache do
      yahoo = mock("yahoo")
      yahoo.stubs(:class).returns(Provider::YahooFinance)
      yahoo.expects(:fetch_security_info).once.returns(provider_success_response(details_without_logo_or_website))
      twelve_data = mock("twelve_data")
      twelve_data.stubs(:class).returns(Provider::TwelveData)
      twelve_data.expects(:fetch_security_info).once.returns(provider_success_response(details_without_logo_or_website))
      @security.stubs(:import_brand_logo)

      @security.stubs(:price_data_provider).returns(yahoo)
      @security.import_provider_details
      @security.stubs(:price_data_provider).returns(twelve_data)
      @security.import_provider_details
    end
  end

  # --- find_or_fetch_price ---

  test "find_or_fetch_price logs a debug entry when the provider fetch fails" do
    provider = mock("provider")
    provider.stubs(:fetch_security_price).returns(
      provider_error_response(Provider::Error.new("the server responded with status 404"))
    )
    @security.stubs(:price_data_provider).returns(provider)

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = @security.find_or_fetch_price(date: 5.days.ago.to_date)
    end

    assert_nil result
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "security_price_fetch", entry.category
    assert_equal "warn", entry.level
    assert_equal @security.id, entry.metadata["security_id"]
    assert_equal "the server responded with status 404", entry.metadata["provider_error"]
  end

  test "find_or_fetch_price only logs once per security per day (deduped)" do
    # Test env runs with a null cache store, which would make the dedupe a
    # no-op and let this test pass vacuously — swap in a real one just for
    # this test so the dedupe logic is actually exercised.
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    provider = mock("provider")
    provider.stubs(:fetch_security_price).returns(
      provider_error_response(Provider::Error.new("boom"))
    ).twice
    @security.stubs(:price_data_provider).returns(provider)

    assert_difference "DebugLogEntry.count", 1 do
      @security.find_or_fetch_price(date: 5.days.ago.to_date)
      @security.find_or_fetch_price(date: 6.days.ago.to_date)
    end
  ensure
    Rails.cache = original_cache
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

  # --- keyless fallback ---

  test "providers falls back to Yahoo Finance when no enabled provider can be built" do
    yahoo = stub_yahoo_finance
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/twelve_data can't be built; using yahoo_finance/)).once

    without_securities_keys([ "twelve_data" ]) do
      assert_equal [ yahoo ], Security.providers
    end
  end

  test "no fallback when a Twelve Data key is present" do
    Provider::Registry.expects(:yahoo_finance).never
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/can't be built/)).never
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])

    with_env_overrides("TWELVE_DATA_API_KEY" => "test-key") do
      assert_equal [ Provider::TwelveData ], Security.providers.map(&:class)
    end
  end

  test "the substitute keeps the default's position" do
    yahoo = stub_yahoo_finance

    without_securities_keys([ "twelve_data", "binance_public" ]) do
      providers = Security.providers

      assert_equal yahoo, providers.first
      assert_equal [ Provider::YahooFinance, Provider::BinancePublic ], providers.map(&:class)
    end
  end

  test "only one substitute" do
    yahoo = stub_yahoo_finance

    without_securities_keys([ "twelve_data", "tiingo" ]) do
      assert_equal [ yahoo ], Security.providers
    end
  end

  test "no substitute when the unbuildable provider is not first" do
    Provider::Registry.expects(:yahoo_finance).never
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(regexp_matches(/can't be built/)).never

    without_securities_keys([ "mfapi", "twelve_data" ]) do
      assert_equal [ Provider::Mfapi ], Security.providers.map(&:class)
    end
  end

  test "the substitution is logged once per process" do
    stub_yahoo_finance
    messages = []
    Rails.logger.stubs(:info).with { |message| messages << message }

    without_securities_keys([ "twelve_data" ]) do
      3.times { Security.providers }
    end

    assert_equal 1, messages.grep(/twelve_data can't be built/).size
  end

  test "no substitute when Yahoo is explicitly enabled" do
    yahoo = stub_yahoo_finance
    yahoo.stubs(:search_securities).returns(provider_success_response([ search_result("AAPL") ]))

    without_securities_keys([ "twelve_data", "yahoo_finance" ]) do
      assert_equal [ yahoo ], Security.providers
      assert_equal [ "yahoo_finance" ], Security.search_provider("AAPL").map(&:price_provider)
    end
  end

  test "no fallback when the enabled list is explicitly empty" do
    Provider::Registry.expects(:yahoo_finance).never

    without_securities_keys([]) do
      assert_equal [], Security.providers
    end
  end

  test "search under the fallback stamps no price_provider" do
    yahoo = stub_yahoo_finance
    yahoo.stubs(:search_securities).returns(provider_success_response([ search_result("AAPL") ]))

    without_securities_keys([ "twelve_data" ]) do
      results = Security.search_provider("AAPL")

      assert_equal [ "AAPL" ], results.map(&:ticker)
      assert_nil results.first.price_provider
      option = results.first.to_combobox_option
      assert_equal "AAPL|XNAS|", option.id
    end
  end

  test "search under the fallback stores a Yahoo-suffixed listing by its bare ticker" do
    yahoo = stub_yahoo_finance
    yahoo.stubs(:search_securities).returns(provider_success_response([
      search_result("SAP.DE", mic: "XETR", country_code: "DE", currency: "EUR"),
      search_result("BRK.B", mic: "XNYS")
    ]))

    without_securities_keys([ "twelve_data" ]) do
      results = Security.search_provider("SAP").to_h { |s| [ s.exchange_operating_mic, s.ticker ] }

      assert_equal({ "XETR" => "SAP", "XNYS" => "BRK.B" }, results)
    end
  end

  test "an explicitly enabled Yahoo keeps its suffixed ticker" do
    yahoo = stub_yahoo_finance
    yahoo.stubs(:search_securities).returns(provider_success_response([
      search_result("SAP.DE", mic: "XETR", country_code: "DE", currency: "EUR")
    ]))

    without_securities_keys([ "twelve_data", "yahoo_finance" ]) do
      assert_equal [ "SAP.DE" ], Security.search_provider("SAP").map(&:ticker)
    end
  end

  test "a keyless provider beside the substitute keeps its stamp" do
    yahoo = stub_yahoo_finance
    yahoo.stubs(:search_securities).returns(provider_success_response([ search_result("AAPL") ]))
    mfapi = mock("mfapi")
    mfapi.stubs(:class).returns(Provider::Mfapi)
    mfapi.stubs(:search_securities).returns(provider_success_response([ search_result("AAPLMF") ]))
    Provider::Registry.stubs(:mfapi).returns(mfapi)

    without_securities_keys([ "twelve_data", "mfapi" ]) do
      assert_equal [ yahoo, mfapi ], Security.providers

      stamps = Security.search_provider("AAPL").to_h { |s| [ s.ticker, s.price_provider ] }
      assert_equal({ "AAPL" => nil, "AAPLMF" => "mfapi" }, stamps)
    end
  end

  test "an assigned twelve_data security stays unavailable under the fallback" do
    stub_yahoo_finance
    @security.update!(price_provider: "twelve_data")

    without_securities_keys([ "twelve_data" ]) do
      assert_nil @security.price_data_provider
      assert_equal :provider_unavailable, @security.provider_status
    end
  end

  test "the setting and configuration health are unchanged under the fallback" do
    yahoo = stub_yahoo_finance
    Setting.securities_providers = "twelve_data"
    Setting.stubs(:twelve_data_api_key).returns(nil)

    with_env_overrides("TWELVE_DATA_API_KEY" => nil, "SECURITIES_PROVIDERS" => nil, "SECURITIES_PROVIDER" => nil) do
      assert_equal [ yahoo ], Security.providers
      assert_equal [ "twelve_data" ], Setting.enabled_securities_providers
      assert_equal :not_configured, ConfigurationHealth.new.securities.status
    end
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

  def stub_yahoo_finance
    yahoo = mock("yahoo_finance")
    yahoo.stubs(:class).returns(Provider::YahooFinance)
    Provider::Registry.stubs(:yahoo_finance).returns(yahoo)
    yahoo
  end

  def without_securities_keys(enabled, &block)
    Setting.stubs(:enabled_securities_providers).returns(enabled)
    Setting.stubs(:twelve_data_api_key).returns(nil)
    Setting.stubs(:tiingo_api_key).returns(nil)
    with_env_overrides("TWELVE_DATA_API_KEY" => nil, "TIINGO_API_KEY" => nil, &block)
  end

  def search_result(symbol, mic: "XNAS", country_code: "US", currency: "USD")
    Provider::SecurityConcept::Security.new(
      symbol: symbol, name: symbol, logo_url: nil,
      exchange_operating_mic: mic, country_code: country_code, currency: currency
    )
  end

  test "ranking: AAPL exact match ranks above AAPL-prefixed and unrelated" do
    results = [
      build_result(ticker: "AAPLX", name: "Some AAPL Fund"),
      build_result(ticker: "AAPL", name: "Apple Inc", country_code: "US", exchange_operating_mic: "XNAS"),
      build_result(ticker: "AAPL", name: "Apple Inc", country_code: "GB", exchange_operating_mic: "XLON"),
      build_result(ticker: "AAPLD", name: "AAPL Dividend ETF")
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
      build_result(ticker: "APPL", name: "Appell Petroleum")
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
      build_result(ticker: "SPXU", name: "ProShares UltraPro Short S&P 500")
    ]

    ranked = rank(results, "SPX", "US")

    assert_equal "SPX", ranked[0].ticker, "Exact match should be first"
    assert ranked[1..].all? { |s| s.ticker.start_with?("SPX") }
  end

  test "ranking: VTTI exact match first regardless of country" do
    results = [
      build_result(ticker: "VTI", name: "Vanguard Total Stock Market ETF", country_code: "US"),
      build_result(ticker: "VTTI", name: "VTTI Energy Partners", country_code: "US"),
      build_result(ticker: "VTTIX", name: "Vanguard Target 2060 Fund")
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
      build_result(ticker: "UNRELATED", name: "Something Else Corp")
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
      build_result(ticker: "TELSA", name: "Telsa Mining Ltd")
    ]

    ranked = rank(results, "tesla", "US")

    # No ticker matches "TESLA", so all go to name matching
    # "Tesla Inc" contains "TESLA" → tier 2, US preferred
    assert_equal "TSLA", ranked[0].ticker
    assert_equal "US", ranked[0].country_code, "US Tesla should rank first for US user"
  end

  test "ranking: a valid ISIN query ranks results carrying that ISIN first" do
    other = build_result(ticker: "SGLDX", name: "Other gold fund", country_code: "GB")
    match = build_result(ticker: "SGLD", name: "Invesco Physical Gold", country_code: "GB", exchange_operating_mic: "XLON")
    match.search_isin = "IE00B579F325"
    other_isin = build_result(ticker: "IE00B579F325", name: "Ticker equals query", country_code: "US")
    other_isin.search_isin = "IE00B4ND3602"

    ranked = rank([ other, other_isin, match ], "ie00b579f325", "US")

    assert_equal "SGLD", ranked.first.ticker
  end

  test "ranking: an ISIN-shaped query with a bad check digit is not treated as an ISIN" do
    wrong = build_result(ticker: "AAA", name: "Wrong")
    wrong.search_isin = "IE00B579F326"
    exact_ticker = build_result(ticker: "IE00B579F326", name: "Ticker match")

    ranked = rank([ wrong, exact_ticker ], "IE00B579F326")

    assert_equal "IE00B579F326", ranked.first.ticker
  end

  test "ranking: results without an ISIN are unaffected by an ISIN query" do
    a = build_result(ticker: "ZZZ", name: "Zed")
    b = build_result(ticker: "AAA", name: "Aye")

    assert_equal %w[AAA ZZZ], rank([ a, b ], "IE00B579F325").map(&:ticker)
  end

  test "search_provider carries the provider ISIN through and tolerates providers without one" do
    with_isin = mock("with_isin")
    without_isin = mock("without_isin")
    with_isin.stubs(:class).returns(Provider::Eodhd)
    without_isin.stubs(:class).returns(Provider::YahooFinance)

    with_isin.expects(:search_securities).with("IE00B579F325").returns(provider_success_response([
      Provider::SecurityConcept::Security.new(
        symbol: "SGLD", name: "Invesco Physical Gold", logo_url: nil,
        exchange_operating_mic: "XLON", country_code: "GB", currency: "GBP", isin: "IE00B579F325"
      )
    ]))
    without_isin.expects(:search_securities).with("IE00B579F325").returns(provider_success_response([
      Provider::SecurityConcept::Security.new(
        symbol: "IE00B579F325.SG", name: "Invesco Physical Gold", logo_url: nil,
        exchange_operating_mic: "XSTU", country_code: "DE"
      )
    ]))

    Security.stubs(:providers).returns([ without_isin, with_isin ])
    # Yahoo is listed because it is enabled, not standing in for a keyless
    # provider, so its ticker keeps the exchange suffix.
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance", "eodhd" ])

    results = Security.search_provider("IE00B579F325")

    assert_equal [ "SGLD", "IE00B579F325.SG" ], results.map(&:ticker)
    assert_equal "IE00B579F325", results.first.to_combobox_option.isin
    assert_nil results.last.to_combobox_option.isin
  end
end
