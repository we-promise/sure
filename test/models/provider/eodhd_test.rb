require "test_helper"

class Provider::EodhdTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Eodhd.new("test_api_key")
  end

  test "preserves raw EODHD exchange code when no MIC mapping exists" do
    unmapped_exchange_body = [
      {
        "Code" => "NL0014157679",
        "Name" => "ING Select Fund - Actueel Zeer Offensief EUR B Cap",
        "Exchange" => "EUFUND",
        "Country" => "Netherlands",
        "Currency" => "EUR"
      }
    ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(unmapped_exchange_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("NL0014157679")

    assert result.success?
    assert_equal 1, result.data.length

    security = result.data.first
    assert_equal "NL0014157679", security.symbol
    assert_equal "EUFUND", security.exchange_operating_mic
    assert_equal "EUR", security.currency
  end

  test "search keeps the ISIN EODHD returns and leaves it nil when absent" do
    body = [
      { "Code" => "SGLD", "Name" => "Invesco Physical Gold", "Exchange" => "LSE", "Country" => "UK",
        "Currency" => "GBP", "ISIN" => "ie00b579f325" },
      { "Code" => "XYZ", "Name" => "No isin", "Exchange" => "US", "Country" => "USA",
        "Currency" => "USD", "ISIN" => "" },
      { "Code" => "ABC", "Name" => "Missing key", "Exchange" => "US", "Country" => "USA", "Currency" => "USD" }
    ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("IE00B579F325")

    assert result.success?
    assert_equal [ "IE00B579F325", nil, nil ], result.data.map(&:isin)
  end

  test "uses mapped MIC when exchange code is in mapping" do
    mapped_exchange_body = [
      {
        "Code" => "AAPL",
        "Name" => "Apple Inc.",
        "Exchange" => "US",
        "Country" => "USA",
        "Currency" => "USD"
      }
    ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(mapped_exchange_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("AAPL")

    assert result.success?
    assert_equal 1, result.data.length

    security = result.data.first
    assert_equal "AAPL", security.symbol
    assert_equal "XNYS", security.exchange_operating_mic
    assert_equal "USD", security.currency
  end

  test "eodhd_symbol uses EUFUND exchange code correctly" do
    ticker = @provider.send(:eodhd_symbol, "NL0014157679", "EUFUND")
    assert_equal "NL0014157679.EUFUND", ticker
  end

  test "eodhd_symbol falls back to US when MIC is nil" do
    ticker = @provider.send(:eodhd_symbol, "TEST", nil)
    assert_equal "TEST.US", ticker
  end

  test "eodhd_symbol uses MIC mapping when available" do
    ticker = @provider.send(:eodhd_symbol, "AAPL", "XNYS")
    assert_equal "AAPL.US", ticker
  end

  test "maps Warsaw exchange WAR to ISO MIC XWAR with PLN" do
    warsaw_body = [
      {
        "Code" => "KTY",
        "Name" => "Grupa Kety SA",
        "Exchange" => "WAR",
        "Country" => "Poland",
        "Currency" => "PLN"
      }
    ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(warsaw_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("KTY")

    assert result.success?
    security = result.data.first
    assert_equal "KTY", security.symbol
    assert_equal "XWAR", security.exchange_operating_mic
    assert_equal "PL", security.country_code
    assert_equal "PLN", security.currency
  end

  test "eodhd_symbol maps other US venues to the composite US code" do
    assert_equal "XLF.US", @provider.send(:eodhd_symbol, "XLF", "ARCX")
    assert_equal "SPY.US", @provider.send(:eodhd_symbol, "SPY", "BATS")
    assert_equal "NSRGY.US", @provider.send(:eodhd_symbol, "NSRGY", "OTCM")
    assert_equal "NVDA.US", @provider.send(:eodhd_symbol, "NVDA", "XNGS")
    assert_equal "XLF.US", @provider.send(:eodhd_symbol, "XLF", "XARC")
    assert_equal "NSRGY.US", @provider.send(:eodhd_symbol, "NSRGY", "XOTC")
  end

  EODHD_EUROPEAN_VENUES = {
    "XFRA" => "F", "XBRU" => "BR", "XLIS" => "LS", "XWBO" => "VI", "XDUB" => "IR",
    "XBER" => "BE", "XDUS" => "DU", "XHAM" => "HM", "XHAN" => "HA", "XMUN" => "MU", "XSTU" => "STU"
  }.freeze

  test "eodhd_symbol maps further European MICs to their EODHD codes" do
    EODHD_EUROPEAN_VENUES.each do |mic, code|
      assert_equal "ABC.#{code}", @provider.send(:eodhd_symbol, "ABC", mic), "#{mic} should map to #{code}"
    end
  end

  test "eodhd_symbol still accepts the raw EODHD code stored by earlier searches" do
    EODHD_EUROPEAN_VENUES.each_value do |code|
      assert_equal "ABC.#{code}", @provider.send(:eodhd_symbol, "ABC", code)
    end
  end

  test "currency_for the further European venues falls back to EUR" do
    EODHD_EUROPEAN_VENUES.each do |mic, code|
      assert_equal "EUR", @provider.send(:currency_for, exchange_operating_mic: mic, symbol: "ABC")
      assert_equal "EUR", @provider.send(:currency_for, exchange_operating_mic: code, symbol: "ABC")
    end
  end

  test "currency_for reads the currency a search cached under the MIC for a legacy raw-code row" do
    EODHD_EUROPEAN_VENUES.each do |mic, code|
      Rails.cache.stubs(:read).with("eodhd:currency:ABC:#{mic}").returns("NOK")
      Rails.cache.stubs(:read).with("eodhd:currency:ABC:#{code}").returns(nil)

      assert_equal "NOK", @provider.send(:currency_for, exchange_operating_mic: code, symbol: "ABC"), "legacy #{code} should find the #{mic} cache"
    end
  end

  test "search maps further European EODHD exchange codes to MICs Sure can name" do
    body = EODHD_EUROPEAN_VENUES.values.map do |code|
      { "Code" => "ABC#{code}", "Name" => "Fund #{code}", "Exchange" => code, "Country" => "Germany", "Currency" => "EUR" }
    end.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.search_securities("ABC")

    assert result.success?
    assert_equal EODHD_EUROPEAN_VENUES.keys, result.data.map(&:exchange_operating_mic)
    assert result.data.all? { |s| ::Security::EXCHANGES.key?(s.exchange_operating_mic) }
  end

  test "eodhd_symbol builds Warsaw ticker from XWAR MIC" do
    assert_equal "KTY.WAR", @provider.send(:eodhd_symbol, "KTY", "XWAR")
  end

  test "eodhd_symbol builds Warsaw ticker from legacy WAR MIC" do
    assert_equal "KTY.WAR", @provider.send(:eodhd_symbol, "KTY", "WAR")
  end

  test "fetch_security_prices uses PLN for XWAR without currency cache" do
    Rails.cache.clear

    eod_body = [
      { "date" => "2026-08-21", "close" => 1213.0 },
      { "date" => "2026-08-22", "close" => 1227.0 }
    ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(eod_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_security_prices(
      symbol: "KTY",
      exchange_operating_mic: "XWAR",
      start_date: Date.new(2026, 8, 21),
      end_date: Date.new(2026, 8, 22)
    )

    assert result.success?
    assert_equal 2, result.data.length
    assert result.data.all? { |price| price.currency == "PLN" }
    assert_equal [ 1213.0, 1227.0 ], result.data.map { |price| price.price.to_f }
  end

  test "fetch_security_prices uses PLN for legacy WAR MIC without cache" do
    Rails.cache.clear

    eod_body = [ { "date" => "2026-08-21", "close" => 1213.0 } ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(eod_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_security_prices(
      symbol: "KTY",
      exchange_operating_mic: "WAR",
      start_date: Date.new(2026, 8, 21),
      end_date: Date.new(2026, 8, 21)
    )

    assert result.success?
    assert_equal "PLN", result.data.first.currency
  end

  test "fetch_security_prices prefers cached per-security currency over exchange default" do
    # LSE venue default is GBP, but this listing is USD-denominated in search results.
    # Test env uses null_store, so stub the cache read the provider would see after search.
    Rails.cache.stubs(:read).with("eodhd:currency:BABA:XLON").returns("USD")

    eod_body = [ { "date" => "2026-08-21", "close" => 85.5 } ].to_json

    mock_response = mock
    mock_response.stubs(:body).returns(eod_body)

    @provider.stubs(:enforce_daily_limit!)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    result = @provider.fetch_security_prices(
      symbol: "BABA",
      exchange_operating_mic: "XLON",
      start_date: Date.new(2026, 8, 21),
      end_date: Date.new(2026, 8, 21)
    )

    assert result.success?
    assert_equal "USD", result.data.first.currency
  end

  test "clamps history to one year at the free-tier request cap" do
    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      assert_equal 365, @provider.max_history_days
    end
  end

  test "does not clamp history when the request cap is raised for a paid plan" do
    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => "100000") do
      assert_nil @provider.max_history_days
    end
  end

  test "fetch_security_info does not retry a failed fundamentals lookup" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).once.raises(Faraday::ForbiddenError.new("403"))

    2.times do
      result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")
      assert_not result.success?
    end
    # The refused (403) call is counted as one request, not ten
    assert_equal 1, Rails.cache.read("eodhd:daily:#{Date.current}")
  end

  test "fetch_security_info retries after a transient failure" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    ok = mock
    ok.stubs(:body).returns({ "General" => { "Name" => "Apple Inc" } }.to_json)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).times(3).raises(Faraday::ServerError.new("502"))
      .then.raises(Faraday::TimeoutError.new("timeout")).then.returns(ok)

    # Three fundamentals calls cost 30 requests, more than the free cap, so use a paid limit
    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => "100") do
      2.times { assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success? }
      assert @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
    end
  end

  test "a fundamentals call counts as ten requests against the daily limit" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    ok = mock
    ok.stubs(:body).returns({ "General" => { "Name" => "Apple Inc" } }.to_json)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).once.returns(ok)

    assert @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
    assert_equal 10, Rails.cache.read("eodhd:daily:#{Date.current}")
  end

  test "a fundamentals call is refused when fewer than ten requests remain" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Rails.cache.write("eodhd:daily:#{Date.current}", 15)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).never

    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      result = @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS")

      assert_not result.success?
      assert_kind_of Provider::Eodhd::RateLimitError, result.error
    end
  end

  test "a refused fundamentals call leaves the remaining requests for prices" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Rails.cache.write("eodhd:daily:#{Date.current}", 15)
    @provider.stubs(:throttle_request)

    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
      assert_equal 15, Rails.cache.read("eodhd:daily:#{Date.current}")

      prices = mock
      prices.stubs(:body).returns([ { "date" => "2026-08-21", "close" => 1.0 } ].to_json)
      @provider.stubs(:client).returns(mock_client = mock)
      mock_client.expects(:get).once.returns(prices)

      assert @provider.fetch_security_prices(
        symbol: "AAPL", exchange_operating_mic: "XNYS",
        start_date: Date.new(2026, 8, 21), end_date: Date.new(2026, 8, 21)
      ).success?
    end
  end

  test "fundamentals refused by the plan do not use up the day's price requests" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    prices = mock
    prices.stubs(:body).returns([ { "date" => "2026-08-21", "close" => 1.0 } ].to_json)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).raises(Faraday::ForbiddenError.new("403")).then
      .raises(Faraday::ForbiddenError.new("403")).then.returns(prices)

    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
      assert_not @provider.fetch_security_info(symbol: "MSFT", exchange_operating_mic: "XNYS").success?
      assert_equal 2, Rails.cache.read("eodhd:daily:#{Date.current}")

      assert @provider.fetch_security_prices(
        symbol: "AAPL", exchange_operating_mic: "XNYS",
        start_date: Date.new(2026, 8, 21), end_date: Date.new(2026, 8, 21)
      ).success?
    end
  end

  test "a fundamentals lookup for an unknown ticker still counts as ten requests" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).once.raises(Faraday::ResourceNotFound.new("404"))

    assert_not @provider.fetch_security_info(symbol: "NOPE", exchange_operating_mic: "XNYS").success?
    assert_equal 10, Rails.cache.read("eodhd:daily:#{Date.current}")
  end

  test "a fundamentals answer that carries an error still counts as ten requests" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    answered = mock
    answered.stubs(:body).returns({ "error" => "Ticker not found" }.to_json)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.expects(:get).once.returns(answered)

    assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
    assert_equal 10, Rails.cache.read("eodhd:daily:#{Date.current}")
  end

  test "taking a refused request back off the count never makes it negative" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    key = "eodhd:daily:#{Date.current}"
    store.write(key, 15)
    # The counter is evicted (or the cache cleared) between the increment and the refund
    original_decrement = store.method(:decrement)
    store.define_singleton_method(:decrement) do |name, amount = 1, **options|
      delete(name)
      original_decrement.call(name, amount, **options)
    end
    @provider.stubs(:throttle_request)

    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?
    end
    assert_equal 0, store.read(key).to_i
  end

  test "a fundamentals call refused with 402 for lack of calls is not counted" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Rails.cache.write("eodhd:daily:#{Date.current}", 10)
    @provider.stubs(:throttle_request)
    @provider.stubs(:client).returns(mock_client = mock)
    # Twice: a 402 leaves no "failed recently" marker, so the next lookup still asks EODHD
    mock_client.expects(:get).twice.raises(Faraday::ClientError.new("402", { status: 402 }))

    with_env_overrides("EODHD_MAX_REQUESTS_PER_DAY" => nil) do
      2.times { assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success? }
    end
    assert_equal 10, Rails.cache.read("eodhd:daily:#{Date.current}")
  end

  test "a 403 that arrives after midnight is refunded to the day it was counted on" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider.stubs(:throttle_request)
    test_case = self
    client = Object.new
    client.define_singleton_method(:get) do |*|
      test_case.travel_to Time.zone.local(2026, 8, 22, 0, 0, 1)
      # Price requests already counted on the new day
      Rails.cache.write("eodhd:daily:2026-08-22", 5)
      raise Faraday::ForbiddenError, "403"
    end
    @provider.stubs(:client).returns(client)

    travel_to Time.zone.local(2026, 8, 21, 23, 59, 59)
    assert_not @provider.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNYS").success?

    assert_equal 1, Rails.cache.read("eodhd:daily:2026-08-21")
    assert_equal 5, Rails.cache.read("eodhd:daily:2026-08-22")
  end

  # The counter is written with `increment`, which stores a raw integer on Redis,
  # so it can only be read back on a real RedisCacheStore; the test env's null
  # store and a MemoryStore both hide a plain `read` returning nil.
  test "usage reports the daily request count on a real Redis cache" do
    store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379"),
      namespace: "test:eodhd:#{SecureRandom.hex(8)}"
    )
    Rails.stubs(:cache).returns(store)
    stub_request(:get, %r{/api/user}).to_return(
      status: 200,
      body: { dailyRateLimit: 20, subscriptionType: "free" }.to_json
    )

    @provider.send(:enforce_daily_limit!)
    @provider.send(:enforce_daily_limit!)

    assert_equal 2, @provider.usage.data.used
  ensure
    store&.clear
  end
end
