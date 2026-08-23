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
    Rails.cache.write("eodhd:currency:BABA:XLON", "USD", expires_in: 24.hours)

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
end
