require "test_helper"
require "ostruct"

class Security::ResolverTest < ActiveSupport::TestCase
  include ProviderTestHelper

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
            .with("NVDA", exchange_operating_mic: "XNAS", country_code: "US", technical_failure: anything)
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
            .with("TEST", exchange_operating_mic: "XNAS", technical_failure: anything)
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
            .with("VWCE", exchange_operating_mic: "XETR", technical_failure: anything)
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
            .with("BTCUSD", exchange_operating_mic: "BNCX", country_code: "US", technical_failure: anything)
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

  test "resolved provider match copies name but not logo_url from the search result" do
    # Name is backfilled directly from the search match (it's already known
    # at resolve time and some providers, e.g. TwelveData on lower plan
    # tiers, gate /profile entirely — without this the name would never
    # populate). logo_url deliberately stays untouched: it's sourced from
    # fetch_security_info/Brandfetch instead, so those paths still run
    # exactly as before on first sync.
    match = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: nil,
      name: "BTC",
      logo_url: "https://cdn.brandfetch.io/crypto/BTC/icon/fallback/lettermark/w/120/h/120?c=test",
      price_provider: "binance_public"
    )

    Security.expects(:search_provider)
            .with("BTCUSD", exchange_operating_mic: "BNCX", country_code: "US", technical_failure: anything)
            .returns([ match ])

    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])

    resolved = Security::Resolver.new(
      "BTCUSD",
      exchange_operating_mic: "BNCX",
      country_code: "US",
      price_provider: "binance_public"
    ).resolve

    assert_equal "BTC", resolved.reload.name, "Resolver should copy name from the search match"
    assert_nil resolved.logo_url, "Resolver must not copy logo_url from the search match"
  end

  test "does not overwrite an existing (e.g. user-edited) name on re-resolve" do
    # country_code intentionally mismatches the resolver call below, so
    # exact_match_from_db (which requires an exact country match) misses and
    # falls through to the provider-match path — which finds the same
    # ticker+MIC record via find_or_create_provider_match! and must not
    # clobber its existing name.
    db_security = Security.create!(ticker: "CSPX3", exchange_operating_mic: "XLON", country_code: "US", name: "Custom Name")
    match = Security.new(ticker: "CSPX3", exchange_operating_mic: "XLON", country_code: "GB", name: "iShares Core S&P 500", price_provider: "tiingo")

    Security.expects(:search_provider)
            .with("CSPX3", exchange_operating_mic: "XLON", country_code: "GB", technical_failure: anything)
            .returns([ match ])
    Setting.stubs(:enabled_securities_providers).returns([ "tiingo" ])

    resolved = Security::Resolver.new("CSPX3", exchange_operating_mic: "XLON", country_code: "GB", price_provider: "tiingo").resolve

    assert_equal db_security, resolved
    assert_equal "Custom Name", resolved.reload.name
  end

  test "marks security resolution_pending (not a generic offline fallback) when provider search fails technically" do
    bad_provider = mock("bad_provider")
    bad_provider.stubs(:class).returns(Provider::YahooFinance)
    bad_provider.expects(:search_securities).with("XMAW").raises(StandardError, "rate limited")

    Security.stubs(:providers).returns([ bad_provider ])
    Security.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("XMAW").resolve

      assert resolved.persisted?
      assert resolved.offline?
      assert_equal "resolution_pending", resolved.offline_reason
    end
  end

  test "genuine no-match from a successful provider search still uses the generic offline fallback" do
    Security.expects(:search_provider).returns([])

    resolved = Security::Resolver.new("FOO2").resolve

    assert resolved.offline?
    assert_nil resolved.offline_reason
  end

  test "reactivates an offline security when the user explicitly re-selects a valid provider, regardless of offline_reason" do
    db_security = Security.create!(
      ticker: "DIS2",
      exchange_operating_mic: "XNYS",
      country_code: "US",
      price_provider: "twelve_data",
      offline: true,
      offline_reason: nil, # e.g. left blank by an old offline_security fallback, or health_check_failed
      failed_fetch_count: 3
    )

    Security.expects(:search_provider).never
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Security.stubs(:provider_for).with("twelve_data").returns(mock("twelve_data_provider"))

    resolved = Security::Resolver.new(
      "DIS2",
      exchange_operating_mic: "XNYS",
      country_code: "US",
      price_provider: "twelve_data"
    ).resolve

    assert_equal db_security, resolved
    resolved.reload
    refute resolved.offline?, "Explicit re-selection of a valid provider must bring the security back online"
    assert_nil resolved.offline_reason
    assert_equal 0, resolved.failed_fetch_count
  end

  test "does not reactivate an offline security during an automated sync (no explicit price_provider)" do
    db_security = Security.create!(
      ticker: "DIS3",
      exchange_operating_mic: "XNYS",
      country_code: "US",
      price_provider: "twelve_data",
      offline: true,
      offline_reason: "health_check_failed",
      failed_fetch_count: 6
    )

    Security.expects(:search_provider).never
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Security.stubs(:provider_for).with("twelve_data").returns(mock("twelve_data_provider"))

    resolved = Security::Resolver.new(
      "DIS3",
      exchange_operating_mic: "XNYS",
      country_code: "US"
    ).resolve

    assert_equal db_security, resolved
    resolved.reload
    assert resolved.offline?, "Automated syncs must not silently bring a failed security back online"
    assert_equal "health_check_failed", resolved.offline_reason
  end

  test "offline_security does not overwrite an existing, more specific offline_reason with resolution_pending" do
    db_security = Security.create!(
      ticker: "XMAW3",
      exchange_operating_mic: "XNAS",
      country_code: "US",
      offline: true,
      offline_reason: "health_check_failed"
    )

    bad_provider = mock("bad_provider")
    bad_provider.stubs(:class).returns(Provider::YahooFinance)
    bad_provider.expects(:search_securities).with("XMAW3", exchange_operating_mic: "XNAS", country_code: "GB").raises(StandardError, "rate limited")

    Security.stubs(:providers).returns([ bad_provider ])
    Security.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])

    # A different country_code this time so the exact DB lookup (which
    # filters by country_code when present) misses the existing "US" record
    # and falls through to a (failing) provider search.
    resolved = Security::Resolver.new("XMAW3", exchange_operating_mic: "XNAS", country_code: "GB").resolve

    assert_equal db_security, resolved
    resolved.reload
    assert resolved.offline?
    assert_equal "health_check_failed", resolved.offline_reason
  end

  test "bypasses the DB fast path and retries the provider for a resolution_pending security" do
    db_security = Security.create!(
      ticker: "XMAW4",
      exchange_operating_mic: "XNAS",
      country_code: "US",
      offline: true,
      offline_reason: "resolution_pending",
      failed_fetch_count: 2
    )

    good_provider = mock("good_provider")
    good_provider.stubs(:class).returns(Provider::YahooFinance)
    good_provider.expects(:search_securities).with("XMAW4", exchange_operating_mic: "XNAS", country_code: "US").returns(
      Provider::Response.new(
        success?: true,
        data: [ OpenStruct.new(symbol: "XMAW4", name: "Test Co", exchange_operating_mic: "XNAS", country_code: "US", logo_url: nil) ],
        error: nil
      )
    )

    Security.stubs(:providers).returns([ good_provider ])
    Security.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])
    Security.stubs(:provider_for).with("yahoo_finance").returns(good_provider)

    resolved = Security::Resolver.new("XMAW4", exchange_operating_mic: "XNAS", country_code: "US").resolve

    assert_equal db_security, resolved
    resolved.reload
    refute resolved.offline?, "A resolution_pending security must come back online once the provider search succeeds again"
    assert_nil resolved.offline_reason
    assert_equal 0, resolved.failed_fetch_count
  end

  test "clears resolution_pending once a successful provider search confirms there is no match" do
    db_security = Security.create!(
      ticker: "XMAW5",
      exchange_operating_mic: "XNAS",
      country_code: "US",
      offline: true,
      offline_reason: "resolution_pending"
    )

    Security.expects(:search_provider).returns([])

    resolved = Security::Resolver.new("XMAW5", exchange_operating_mic: "XNAS", country_code: "US").resolve

    assert_equal db_security, resolved
    resolved.reload
    assert resolved.offline?
    assert_nil resolved.offline_reason, "A confirmed no-match must stop the DB fast-path bypass on later resolves"
  end

  test "settles a blank-exchange resolution_pending placeholder instead of creating a second security" do
    provider = mock("yahoo_finance")
    provider.stubs(:class).returns(Provider::YahooFinance)
    provider.stubs(:search_securities).with("ABCDX")
      .raises(StandardError, "rate limited")
      .then.returns(provider_success_response([
        Provider::SecurityConcept::Security.new(
          symbol: "ABCDX", name: "ABCD Fund", logo_url: nil,
          exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
        )
      ]))
      .then.raises(StandardError, "rate limited")

    Security.stubs(:providers).returns([ provider ])
    Security.stubs(:provider_for).with("yahoo_finance").returns(provider)
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])

    # First sync: the search fails, so holdings land on a blank-MIC placeholder.
    placeholder = Security::Resolver.new("ABCDX").resolve
    assert_nil placeholder.exchange_operating_mic
    assert_equal "resolution_pending", placeholder.offline_reason

    assert_no_difference "Security.count" do
      # Next sync: the search works, and the placeholder becomes the match.
      resolved = Security::Resolver.new("ABCDX").resolve

      assert_equal placeholder, resolved
      resolved.reload
      assert_equal "XNAS", resolved.exchange_operating_mic
      assert_equal "US", resolved.country_code
      assert_equal "ABCD Fund", resolved.name
      refute resolved.offline?
      assert_nil resolved.offline_reason

      # A later sync finds it in the DB, even while the search is failing again.
      assert_equal placeholder, Security::Resolver.new("ABCDX").resolve
    end
  end

  test "leaves a resolution_pending placeholder from another country alone" do
    placeholder = Security.create!(ticker: "SHOPX", country_code: "CA", offline: true, offline_reason: "resolution_pending")
    us_listing = Security.new(ticker: "SHOPX", exchange_operating_mic: "XNYS", country_code: "US")

    Security.expects(:search_provider).returns([ us_listing ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("SHOPX").resolve

      refute_equal placeholder, resolved
      assert_equal "XNYS", resolved.exchange_operating_mic
    end

    placeholder.reload
    assert_nil placeholder.exchange_operating_mic
    assert_equal "resolution_pending", placeholder.offline_reason
  end

  test "does not take over a blank-exchange security that is not resolution_pending" do
    no_match = Security.create!(ticker: "NOMX", offline: true, offline_reason: nil)
    listing = Security.new(ticker: "NOMX", exchange_operating_mic: "XNAS", country_code: "US")

    Security.expects(:search_provider).returns([ listing ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("NOMX", exchange_operating_mic: "XNAS").resolve

      refute_equal no_match, resolved
    end

    assert_nil no_match.reload.exchange_operating_mic
  end

  test "does not relabel a placeholder another sync claimed for a different exchange meanwhile" do
    placeholder = Security.create!(ticker: "RACEX", offline: true, offline_reason: "resolution_pending")
    as_read = Security.find(placeholder.id) # before the other sync's claim committed
    placeholder.update!(exchange_operating_mic: "XNYS", offline: false, offline_reason: nil)

    Security::Resolver.any_instance.stubs(:pending_placeholder_candidate).returns(as_read)
    Security.expects(:search_provider).returns([ Security.new(ticker: "RACEX", exchange_operating_mic: "XNAS", country_code: "US") ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new("RACEX", exchange_operating_mic: "XNAS").resolve

      refute_equal placeholder, resolved
      assert_equal "XNAS", resolved.exchange_operating_mic
    end

    assert_equal "XNYS", placeholder.reload.exchange_operating_mic
  end

  test "uses a placeholder another sync settled on the same exchange meanwhile" do
    placeholder = Security.create!(ticker: "RACEY", offline: true, offline_reason: "resolution_pending")
    as_read = Security.find(placeholder.id) # before the other sync's claim committed
    placeholder.update!(exchange_operating_mic: "XNAS", offline: false, offline_reason: nil)

    # This sync's own lookup ran before that claim too, so it found no XNAS row.
    Security.stubs(:find_or_initialize_by_ticker_and_exchange).returns(Security.new(ticker: "RACEY", exchange_operating_mic: "XNAS"))
    Security::Resolver.any_instance.stubs(:pending_placeholder_candidate).returns(as_read)
    Security.expects(:search_provider).returns([ Security.new(ticker: "RACEY", exchange_operating_mic: "XNAS", country_code: "US") ])

    assert_no_difference "Security.count" do
      assert_equal placeholder, Security::Resolver.new("RACEY", exchange_operating_mic: "XNAS", country_code: "US").resolve
    end
  end

  test "looks again when another sync claims the placeholder for this exchange after this sync's lookup" do
    placeholder = Security.create!(ticker: "RACEZ", offline: true, offline_reason: "resolution_pending")
    Security.expects(:search_provider).returns([ Security.new(ticker: "RACEZ", exchange_operating_mic: "XNAS", country_code: "US") ])

    resolver = Security::Resolver.new("RACEZ", exchange_operating_mic: "XNAS", country_code: "US")
    # This sync's lookup found no XNAS row. The other sync's claim lands before
    # this sync looks for a placeholder, so it finds none and builds a new row.
    resolver.define_singleton_method(:pending_placeholder_candidate) do |_match|
      placeholder.update!(exchange_operating_mic: "XNAS", offline: false, offline_reason: nil)
      nil
    end

    assert_no_difference "Security.count" do
      assert_equal placeholder, resolver.resolve
    end
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

  test "canonicalizes legacy WAR MIC to XWAR on resolve and reuses existing row" do
    legacy = Security.create!(ticker: "KTY", exchange_operating_mic: "XWAR", country_code: "PL")
    legacy.update_columns(exchange_operating_mic: "WAR")

    Security.expects(:search_provider).never

    resolved = Security::Resolver.new("KTY", exchange_operating_mic: "WAR", country_code: "PL").resolve

    assert_equal legacy.id, resolved.id
    assert_equal "XWAR", resolved.reload.exchange_operating_mic
  end

  test "WAR and XWAR resolve to the same security without creating a duplicate" do
    match = Security.new(ticker: "KTY", exchange_operating_mic: "XWAR", country_code: "PL", price_provider: "eodhd")

    Security.expects(:search_provider)
            .with("KTY", exchange_operating_mic: "XWAR", country_code: "PL", technical_failure: anything)
            .returns([ match ])

    Setting.stubs(:enabled_securities_providers).returns([ "eodhd" ])

    assert_difference "Security.count", 1 do
      resolved = Security::Resolver.new(
        "KTY",
        exchange_operating_mic: "WAR",
        country_code: "PL",
        price_provider: "eodhd"
      ).resolve

      assert_equal "XWAR", resolved.exchange_operating_mic
    end

    Security.expects(:search_provider).never

    assert_no_difference "Security.count" do
      again = Security::Resolver.new(
        "KTY",
        exchange_operating_mic: "XWAR",
        country_code: "PL",
        price_provider: "eodhd"
      ).resolve

      assert_equal "XWAR", again.exchange_operating_mic
      assert_equal 1, Security.where("UPPER(ticker) = ?", "KTY").count
    end
  end

  test "prefers canonical XWAR when both WAR and XWAR rows exist" do
    canonical = Security.create!(ticker: "KTY", exchange_operating_mic: "XWAR", country_code: "PL")
    legacy = Security.new(ticker: "KTY", exchange_operating_mic: "WAR", country_code: "PL")
    legacy.save!(validate: false)

    Security.expects(:search_provider).never

    resolved = Security::Resolver.new("KTY", exchange_operating_mic: "WAR", country_code: "PL").resolve

    assert_equal canonical.id, resolved.id
    assert_equal "XWAR", resolved.exchange_operating_mic
  end

  test "persists WAR lookups as canonical XWAR" do
    Security.expects(:search_provider).returns([])

    resolved = Security::Resolver.new("KTY", exchange_operating_mic: "WAR", country_code: "PL").resolve

    assert resolved.persisted?
    assert_equal "XWAR", resolved.exchange_operating_mic
  end

  test "upgrades a legacy GER row when Yahoo now reports XETR instead of creating a duplicate" do
    legacy = Security.create!(ticker: "SXR8.DE", exchange_operating_mic: "XETR", country_code: "DE")
    legacy.update_columns(exchange_operating_mic: "GER")

    Security.expects(:search_provider).never

    assert_no_difference "Security.count" do
      resolved = Security::Resolver.new("SXR8.DE", exchange_operating_mic: "XETR", country_code: "DE").resolve

      assert_equal legacy.id, resolved.id
      assert_equal "XETR", resolved.reload.exchange_operating_mic
    end
  end

  test "prefers canonical XETR when both GER and XETR rows exist" do
    canonical = Security.create!(ticker: "SXR8.DE", exchange_operating_mic: "XETR", country_code: "DE")
    legacy = Security.new(ticker: "SXR8.DE", exchange_operating_mic: "GER", country_code: "DE")
    legacy.save!(validate: false)

    Security.expects(:search_provider).never

    resolved = Security::Resolver.new("SXR8.DE", exchange_operating_mic: "GER", country_code: "DE").resolve

    assert_equal canonical.id, resolved.id
    assert_equal "GER", legacy.reload.exchange_operating_mic
  end

  test "upgrades a legacy NEO row when Yahoo now reports NEOE instead of creating a duplicate" do
    legacy = Security.create!(ticker: "CHE-UN.NE", exchange_operating_mic: "NEOE", country_code: "CA")
    legacy.update_columns(exchange_operating_mic: "NEO")

    Security.expects(:search_provider).never

    assert_no_difference "Security.count" do
      resolved = Security::Resolver.new("CHE-UN.NE", exchange_operating_mic: "NEOE", country_code: "CA").resolve

      assert_equal legacy.id, resolved.id
      assert_equal "NEOE", resolved.reload.exchange_operating_mic
    end
  end

  test "a security resolved under the keyless fallback switches to Twelve Data once a key is added" do
    yahoo = mock("yahoo_finance")
    yahoo.stubs(:class).returns(Provider::YahooFinance)
    yahoo.stubs(:search_securities).returns(provider_success_response([
      Provider::SecurityConcept::Security.new(
        symbol: "ZZYF", name: "Fallback Co", logo_url: nil,
        exchange_operating_mic: "XNAS", country_code: "US", currency: "USD"
      )
    ]))
    Provider::Registry.stubs(:yahoo_finance).returns(yahoo)
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Setting.stubs(:twelve_data_api_key).returns(nil)

    resolved = with_env_overrides("TWELVE_DATA_API_KEY" => nil) do
      Security::Resolver.new("ZZYF", exchange_operating_mic: "XNAS", country_code: "US").resolve.tap do |security|
        assert_equal yahoo, security.price_data_provider
      end
    end

    assert_nil resolved.reload.price_provider

    with_env_overrides("TWELVE_DATA_API_KEY" => "test-key") do
      assert_instance_of Provider::TwelveData, resolved.price_data_provider
    end
  end
end
