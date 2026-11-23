require "test_helper"

class ZzProbeTest < ActiveSupport::TestCase
  # Full path: Binance enabled, real resolver, Coinbase Investment account, XRP.
  test "probe full path XRP on Coinbase investment account with binance enabled" do
    Setting.stubs(:enabled_securities_providers).returns([ "binance_public" ])

    symbols = [
      { "symbol" => "XRPUSDT", "baseAsset" => "XRP", "quoteAsset" => "USDT", "status" => "TRADING" },
      { "symbol" => "XRPBTC", "baseAsset" => "XRP", "quoteAsset" => "BTC", "status" => "TRADING" }
    ]
    Provider::BinancePublic.any_instance.stubs(:exchange_info_symbols).returns(symbols)

    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:simplefin_account).returns(stub(name: "Coinbase"))

    resolved = processor.send(:resolve_security, "XRP", "Ripple")
    puts "PROBE3 ticker=#{resolved.ticker.inspect} mic=#{resolved.exchange_operating_mic.inspect} crypto=#{resolved.crypto?.inspect} offline=#{resolved.offline?.inspect}"

    # What the base branch would have done:
    base = Security::Resolver.new("XRP").resolve
    puts "PROBE3 base_resolver ticker=#{base.ticker.inspect} mic=#{base.exchange_operating_mic.inspect} crypto=#{base.crypto?.inspect} offline=#{base.offline?.inspect}"
  end
end
