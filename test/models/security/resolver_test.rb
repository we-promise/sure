require "test_helper"

class Security::ResolverTest < ActiveSupport::TestCase
  test "resolves DB security" do
    # Given an existing security in the DB that exactly matches the lookup params
    db_security = Security.create!(ticker: "TSLA", exchange_operating_mic: "XNAS", country_code: "US")

    # The resolver should return the DB record and never hit the provider
    Security.expects(:search_provider).never

    resolved = Security::Resolver.new("TSLA", exchange_operating_mic: "XNAS", country_code: "US").resolve

    assert_equal db_security, resolved
  end

  test "resolves exact provider match" do
    # Provider returns multiple results, one of which exactly matches symbol + exchange (and country)
    exact_match = Security.new(ticker: "NVDA", exchange_operating_mic: "XNAS", country_code: "US")
    near_miss   = Security.new(ticker: "NVDA", exchange_operating_mic: "XNYS", country_code: "US")

    Security.expects(:search_provider)
            .with("NVDA", exchange_operating_mic: "XNAS", country_code: "US")
            .returns([ near_miss, exact_match ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("NVDA", exchange_operating_mic: "XNAS", country_code: "US").resolve

      assert resolved.persisted?
      assert_equal "NVDA", resolved.ticker
      assert_equal "XNAS", resolved.exchange_operating_mic
      assert_equal "US",   resolved.country_code
      refute resolved.offline, "Exact provider matches should not be marked offline"
    end
  end

  test "resolves close provider match" do
    # No exact match – resolver should choose the most relevant close match based on exchange + country ranking
    preferred = Security.new(ticker: "TEST1", exchange_operating_mic: "XNAS", country_code: "US")
    other     = Security.new(ticker: "TEST2", exchange_operating_mic: "XNYS", country_code: "GB")

    # Return in reverse-priority order to prove the sorter works
    Security.expects(:search_provider)
            .with("TEST", exchange_operating_mic: "XNAS")
            .returns([ other, preferred ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("TEST", exchange_operating_mic: "XNAS").resolve

      assert resolved.persisted?
      assert_equal "TEST1", resolved.ticker
      assert_equal "XNAS",  resolved.exchange_operating_mic
      assert_equal "US",    resolved.country_code
      refute resolved.offline, "Provider matches should not be marked offline"
    end
  end

  test "resolves offline security" do
    Security.expects(:search_provider).returns([])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("FOO").resolve

      assert resolved.persisted?, "Offline security should be saved"
      assert_equal "FOO", resolved.ticker
      assert resolved.offline, "Offline securities should be flagged offline"
    end
  end

  test "returns nil when symbol blank" do
    assert_raises(ArgumentError) { Security::Resolver.new(nil).resolve }
    assert_raises(ArgumentError) { Security::Resolver.new("").resolve }
  end

  test "persists explicit price_provider on DB match" do
    db_security = Security.create!(ticker: "CSPX", exchange_operating_mic: "XLON", country_code: "GB")

    Security.expects(:search_provider).never
    Setting.stubs(:enabled_securities_providers).returns([ "tiingo" ])

    resolved = Security::Resolver.new(
      "CSPX",
      exchange_operating_mic: "XLON",
      country_code: "GB",
      price_provider: "tiingo"
    ).resolve

    assert_equal db_security, resolved
    assert_equal "tiingo", resolved.reload.price_provider
  end

  test "persists price_provider on provider match" do
    match = Security.new(ticker: "VWCE", exchange_operating_mic: "XETR", country_code: "DE", price_provider: "eodhd")

    Security.expects(:search_provider)
            .with("VWCE", exchange_operating_mic: "XETR")
            .returns([ match ])

    Setting.stubs(:enabled_securities_providers).returns([ "eodhd" ])

    resolved = Security::Resolver.new(
      "VWCE",
      exchange_operating_mic: "XETR",
      price_provider: "eodhd"
    ).resolve

    assert resolved.persisted?
    assert_equal "eodhd", resolved.price_provider
  end

  test "rejects unknown price_provider" do
    db_security = Security.create!(ticker: "AAPL2", exchange_operating_mic: "XNAS", country_code: "US")

    Security.expects(:search_provider).never

    resolved = Security::Resolver.new(
      "AAPL2",
      exchange_operating_mic: "XNAS",
      country_code: "US",
      price_provider: "fake_provider"
    ).resolve

    assert_equal db_security, resolved
    assert_nil resolved.reload.price_provider, "Unknown providers should be rejected"
  end

  test "resolves Binance crypto match for a non-AE family" do
    # Regression: BinancePublic search results carry country_code="AE" (the ISO
    # 10383 MIC country), but the transactions controller passes the family's
    # country (e.g. "US"). The resolver used to require an exact country match
    # for both exact and close paths, so non-AE families would fall through to
    # offline_security for every Binance pick — the user saw their BTCUSD
    # holding resolve to an offline security that never fetched prices.
    binance_match = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: nil,
      price_provider: "binance_public"
    )

    Security.expects(:search_provider)
            .with("BTCUSD", exchange_operating_mic: "BNCX", country_code: "US")
            .returns([ binance_match ])

    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])

    resolved = Security::Resolver.new(
      "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: "US",
      price_provider: "binance_public"
    ).resolve

    assert resolved.persisted?
    refute resolved.offline, "Binance security must not fall through to offline_security"
    assert_equal "BTCUSD",         resolved.ticker
    assert_equal "BNCX",           resolved.exchange_operating_mic
    assert_equal "binance_public", resolved.price_provider
  end

  test "resolved provider match is persisted with nil name/logo_url" do
    # Documents that find_or_create_provider_match! intentionally copies only
    # ticker, MIC, country_code, and price_provider from the match — not name
    # or logo_url. This means Security#import_provider_details always has
    # blank metadata on first resolution and does NOT short-circuit at
    # `return if self.name.present? && ...`, so fetch_security_info runs as
    # expected on the first sync. Regression guard: if someone adds name/logo
    # copying to the resolver, the Binance logo-fallback path would become
    # dead code on first sync.
    match = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: nil,
      name: "BTC",
      logo_url: "https://cdn.jsdelivr.net/gh/lindomar-oliveira/binance-data-plus/assets/img/BTC.png",
      price_provider: "binance_public"
    )

    Security.expects(:search_provider)
            .with("BTCUSD", exchange_operating_mic: "BNCX", country_code: "US")
            .returns([ match ])

    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])

    resolved = Security::Resolver.new(
      "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: "US",
      price_provider: "binance_public"
    ).resolve

    assert_nil resolved.reload.name, "Resolver must not copy name from the search match"
    assert_nil resolved.logo_url,    "Resolver must not copy logo_url from the search match"
  end

  test "rejects disabled price_provider" do
    db_security = Security.create!(ticker: "GOOG2", exchange_operating_mic: "XNAS", country_code: "US")

    Security.expects(:search_provider).never
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])

    resolved = Security::Resolver.new(
      "GOOG2",
      exchange_operating_mic: "XNAS",
      country_code: "US",
      price_provider: "tiingo"
    ).resolve

    assert_equal db_security, resolved
    assert_nil resolved.reload.price_provider, "Disabled providers should be rejected"
  end
end
