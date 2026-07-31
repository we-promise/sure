require "test_helper"

class Provider::TiingoTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Tiingo.new("test_api_key")
    @provider.stubs(:throttle_request)
    @provider.stubs(:track_symbol)
  end

  # Real response captured from Tiingo's /tiingo/utilities/search for VFV -
  # note there is no priceCurrency field, only countryCode.
  def vfv_search_body
    [
      {
        "name" => "Vanguard S&P 500 Index ETF",
        "ticker" => "VFV",
        "permaTicker" => "CA000000140493",
        "openFIGIComposite" => nil,
        "assetType" => "ETF",
        "isActive" => true,
        "countryCode" => "CA"
      }
    ].to_json
  end

  def aapl_search_body
    [
      {
        "name" => "Apple Inc",
        "ticker" => "AAPL",
        "permaTicker" => "US0000000123",
        "assetType" => "Stock",
        "isActive" => true,
        "countryCode" => "US"
      }
    ].to_json
  end

  # Real response captured from Tiingo's /tiingo/utilities/search for AAPL -
  # Tiingo returns two entries sharing the exact same ticker, a CA
  # cross-listing (no openFIGIComposite) and the real US primary listing.
  # The CA entry appears first in the array.
  def aapl_duplicate_ticker_search_body
    [
      {
        "name" => "Apple Inc",
        "ticker" => "AAPL",
        "permaTicker" => "CA000000137372",
        "openFIGIComposite" => nil,
        "assetType" => "Stock",
        "isActive" => true,
        "countryCode" => "CA"
      },
      {
        "name" => "Apple Inc",
        "ticker" => "AAPL",
        "permaTicker" => "US000000000038",
        "openFIGIComposite" => "BBG000B9XRY4",
        "assetType" => "Stock",
        "isActive" => true,
        "countryCode" => "US"
      }
    ].to_json
  end

  def stub_client_get(body)
    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)
    mock_client
  end

  # ================================
  #        search_securities
  # ================================

  test "search_securities resolves USD for a US security with no priceCurrency field" do
    stub_client_get(aapl_search_body)

    result = @provider.search_securities("AAPL")

    assert result.success?
    security = result.data.first
    assert_equal "AAPL", security.symbol
    assert_equal "USD", security.currency
  end

  test "search_securities resolves CAD for a Canadian security via countryCode (VFV)" do
    stub_client_get(vfv_search_body)

    result = @provider.search_securities("VFV")

    assert result.success?
    security = result.data.first
    assert_equal "VFV", security.symbol
    assert_equal "CAD", security.currency
    assert_equal "CA", security.country_code
  end

  test "search_securities resolves currency for a country outside the old hardcoded allowlist (FR)" do
    body = [
      { "name" => "Some Fund", "ticker" => "XYZ", "assetType" => "ETF", "isActive" => true, "countryCode" => "FR" }
    ].to_json
    stub_client_get(body)

    result = @provider.search_securities("XYZ")

    assert result.success?
    assert_equal "EUR", result.data.first.currency
  end

  test "search_securities does not populate currency for an unrecognized country code" do
    body = [
      { "name" => "Some Fund", "ticker" => "XYZ", "assetType" => "ETF", "isActive" => true, "countryCode" => "ZZ" }
    ].to_json
    stub_client_get(body)

    result = @provider.search_securities("XYZ")

    assert result.success?
    assert_nil result.data.first.currency
  end

  test "search_securities resolves the same US-listed currency for every entry sharing a ticker across multiple countries (AAPL)" do
    stub_client_get(aapl_duplicate_ticker_search_body)

    result = @provider.search_securities("AAPL")

    assert result.success?
    # Both the CA and US entries share ticker AAPL, and Tiingo's daily-price
    # endpoint is looked up by ticker alone, so both must show the same
    # currency that actually backs the price data (USD, from the US entry) -
    # not each entry's own countryCode - otherwise the currency shown here
    # would disagree with what fetch_security_prices later returns.
    assert_equal [ "USD", "USD" ], result.data.map(&:currency)
  end

  test "search_securities caches the US-listed currency for a ticker with multiple country matches, not just the first array entry" do
    # Test env uses cache_store = :null_store; swap in a real store to inspect
    # what actually gets cached.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    stub_client_get(aapl_duplicate_ticker_search_body)

    @provider.search_securities("AAPL")

    assert_equal "USD", Rails.cache.read("tiingo:currency:AAPL")
  end

  test "search_securities does not downgrade a cached US-derived currency when a later search for the same ticker omits the US entry" do
    # Test env uses cache_store = :null_store; swap in a real store so the
    # cache write from the first search actually persists for the second.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    stub_client_get(aapl_duplicate_ticker_search_body)
    @provider.search_securities("AAPL") # caches USD from the US entry
    assert_equal "USD", Rails.cache.read("tiingo:currency:AAPL")

    # A later search for the same ticker returns a result set that only
    # includes the CA cross-listing (e.g. a different query string surfaced
    # by Tiingo's relevance ranking) - the cached USD (backing the real daily
    # price data) must not be silently overwritten with CAD.
    ca_only_body = [
      {
        "name" => "Apple Inc",
        "ticker" => "AAPL",
        "permaTicker" => "CA000000137372",
        "openFIGIComposite" => nil,
        "assetType" => "Stock",
        "isActive" => true,
        "countryCode" => "CA"
      }
    ].to_json
    stub_client_get(ca_only_body)

    result = @provider.search_securities("AAPL")

    assert result.success?
    assert_equal "USD", Rails.cache.read("tiingo:currency:AAPL")
  end

  # ================================
  #        fetch_security_prices
  # ================================

  test "fetch_security_prices resolves currency from the search-populated cache without a second request" do
    # Test env uses cache_store = :null_store, so writes are no-ops - swap in a
    # real in-memory store for this test to genuinely exercise the
    # write-then-read cache path (matching real dev/production behavior),
    # rather than always falling through to the fallback search.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    mock_client = stub_client_get(vfv_search_body)
    @provider.search_securities("VFV") # populates the tiingo:currency:VFV cache entry

    prices_body = [ { "date" => "2026-06-01T00:00:00.000Z", "close" => 100.5 } ].to_json
    mock_response = mock
    mock_response.stubs(:body).returns(prices_body)
    # .expects(...).once (not .stubs) so this test fails loudly if a second
    # request (the fallback search) is made - the cache hit should avoid it.
    # client is private, so reuse the already-stubbed mock_client rather than
    # calling @provider.client externally.
    mock_client.expects(:get).once.returns(mock_response)

    result = @provider.fetch_security_prices(symbol: "VFV", start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 1))

    assert result.success?, "expected success but got: #{result.error&.message}"
    assert_equal "CAD", result.data.first.currency
  end

  test "fetch_security_prices falls back to a fresh search when the currency isn't cached, and resolves CAD for VFV" do
    prices_body = [ { "date" => "2026-06-01T00:00:00.000Z", "close" => 100.5 } ].to_json
    prices_response = mock
    prices_response.stubs(:body).returns(prices_body)

    search_response = mock
    search_response.stubs(:body).returns(vfv_search_body)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(prices_response).then.returns(search_response)

    result = @provider.fetch_security_prices(symbol: "VFV", start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 1))

    assert result.success?, "expected success but got: #{result.error&.message}"
    assert_equal "CAD", result.data.first.currency
  end

  test "fetch_security_prices resolves USD for AAPL via the fallback search even though the CA entry appears first" do
    prices_body = [ { "date" => "2026-06-01T00:00:00.000Z", "close" => 200.0 } ].to_json
    prices_response = mock
    prices_response.stubs(:body).returns(prices_body)

    search_response = mock
    search_response.stubs(:body).returns(aapl_duplicate_ticker_search_body)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(prices_response).then.returns(search_response)

    result = @provider.fetch_security_prices(symbol: "AAPL", start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 1))

    assert result.success?, "expected success but got: #{result.error&.message}"
    assert_equal "USD", result.data.first.currency
  end

  test "fetch_security_prices fails (does not raise, does not default to USD) when the country code is unrecognized" do
    prices_body = [ { "date" => "2026-06-01T00:00:00.000Z", "close" => 42.0 } ].to_json
    prices_response = mock
    prices_response.stubs(:body).returns(prices_body)

    unmapped_search_body = [
      { "name" => "Some Fund", "ticker" => "ZZZ", "assetType" => "ETF", "isActive" => true, "countryCode" => "ZZ" }
    ].to_json
    search_response = mock
    search_response.stubs(:body).returns(unmapped_search_body)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(prices_response).then.returns(search_response)

    result = @provider.fetch_security_prices(symbol: "ZZZ", start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 1))

    assert_not result.success?
    assert_instance_of Provider::Tiingo::Error, result.error
    assert_match "Could not determine currency", result.error.message
  end
end
