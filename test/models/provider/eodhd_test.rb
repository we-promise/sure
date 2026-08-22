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
end
