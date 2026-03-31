require "test_helper"

class Provider::BinanceTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :parsed_response, :body)

  setup do
    @provider = Provider::Binance.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "handle_response classifies authentication errors returned as bad requests" do
    message = "Invalid API-key, IP, or permissions for action."
    response = Response.new(400, { "msg" => message }, { "msg" => message }.to_json)

    error = assert_raises(Provider::Binance::AuthenticationError) do
      @provider.send(:handle_response, response)
    end

    assert_equal message, error.message
  end

  test "handle_response classifies rate limit errors by message" do
    message = "Too much request weight used; please use the websocket for live updates."
    response = Response.new(400, { "msg" => message }, { "msg" => message }.to_json)

    error = assert_raises(Provider::Binance::RateLimitError) do
      @provider.send(:handle_response, response)
    end

    assert_equal message, error.message
  end

  test "get_daily_klines uses UTC day boundaries even when local timezone is not UTC" do
    original_tz = ENV["TZ"]
    ENV["TZ"] = "Europe/Paris"

    expected_start = Time.utc(2026, 1, 5).beginning_of_day.to_i * 1000
    expected_end = Time.utc(2026, 1, 5).end_of_day.to_i * 1000

    @provider.expects(:public_get).with do |path, params|
      path == "/api/v3/klines" &&
        params[:symbol] == "BTCUSDT" &&
        params[:interval] == "1d" &&
        params[:startTime] == expected_start &&
        params[:endTime] == expected_end &&
        params[:limit] == 1
    end.returns([ [ "kline" ] ])

    assert_equal [ [ "kline" ] ], @provider.get_daily_klines(symbol: "BTCUSDT", date: Date.new(2026, 1, 5))
  ensure
    ENV["TZ"] = original_tz
  end
end
