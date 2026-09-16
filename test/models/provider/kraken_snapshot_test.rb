require "test_helper"
require "ostruct"

class Provider::KrakenSnapshotTest < ActiveSupport::TestCase
  setup do
    @nonce = mock("atomic nonce allocation")
    @provider = Provider::Kraken.new(api_key: "private-key", api_secret: Base64.strict_encode64("private-secret"), nonce_generator: @nonce)
  end

  test "one signed history request uses the allocated nonce scope count and exact decimal response" do
    @nonce.expects(:call).once.returns("1769817600000000001")
    body = "nonce=1769817600000000001&start=1700000000&end=1769817600&ofs=50&without_count=false&limit=50&consolidate_taker=true"
    digest = OpenSSL::Digest::SHA256.digest("1769817600000000001" + body)
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha512", "private-secret", "/0/private/TradesHistory" + digest))
    Provider::Kraken.expects(:post).once.with("/0/private/TradesHistory", body: body, headers: {
      "API-Key" => "private-key", "API-Sign" => signature, "Content-Type" => "application/x-www-form-urlencoded"
    }).returns(response('{"error":[],"result":{"trades":{"fill":{"time":1769817600.123456789,"cost":"1.234567890123456789"}},"count":51}}'))

    result = @provider.get_trades_history_page(start: 1_700_000_000, end_at: 1_769_817_600, offset: 50)

    assert_equal BigDecimal("1769817600.123456789"), result.fetch("result").fetch("trades").fetch("fill").fetch("time")
    assert_equal "1.234567890123456789", result.fetch("result").fetch("trades").fetch("fill").fetch("cost")
    assert_equal 51, result.fetch("result").fetch("count")
  end

  test "each private attempt allocates a distinct nonce and default history omits start" do
    @nonce.expects(:call).returns("1001", "1002").twice
    Provider::Kraken.expects(:post).with("/0/private/Ledgers", has_entries(body: "nonce=1001&end=2000&ofs=0&without_count=false"))
      .returns(response('{"error":[],"result":{"ledger":{},"count":0}}'))
    Provider::Kraken.expects(:post).with("/0/private/BalanceEx", has_entries(body: "nonce=1002"))
      .returns(response('{"error":[],"result":{"XXBT":{"balance":"0.000000000000000001"}}}'))
    assert_equal 0, @provider.get_ledgers_page(end_at: 2000).fetch("result").fetch("count")
    assert_equal "0.000000000000000001", @provider.get_extended_balance_snapshot.fetch("result").fetch("XXBT").fetch("balance")
  end

  test "public catalog and all market ticker snapshots require no nonce or authentication headers" do
    %w[Assets AssetPairs Ticker].each do |endpoint|
      Provider::Kraken.expects(:get).with("/0/public/#{endpoint}", query: {})
        .returns(response('{"error":[],"result":{"precise":0.123456789012345678}}'))
    end
    [ @provider.get_asset_info_snapshot, @provider.get_asset_pairs_snapshot, @provider.get_ticker_snapshot ].each do |result|
      assert_equal BigDecimal("0.123456789012345678"), result.fetch("result").fetch("precise")
    end
  end

  test "invalid nonces and request bounds are rejected before private HTTP" do
    [ "0", "-1", "1&private-key", "9223372036854775808" ].each do |value|
      @nonce.expects(:call).returns(value)
      error = assert_raises(Provider::Kraken::NonceError) { @provider.get_extended_balance_snapshot }
      refute_includes error.message, "private-key"
    end
    assert_raises(ArgumentError) { @provider.get_ledgers_page(start: 2000, end_at: 2000) }
    assert_raises(ArgumentError) { @provider.get_trades_history_page(end_at: 2000, offset: -1) }
  end

  test "native errors retain Kraken classifications without retaining private provider messages" do
    cases = { "EAPI:Invalid key" => Provider::Kraken::AuthenticationError,
      "EAPI:Invalid nonce" => Provider::Kraken::NonceError, "EGeneral:Permission denied" => Provider::Kraken::PermissionError,
      "EService:Throttled" => Provider::Kraken::RateLimitError, "EAPI:otp required" => Provider::Kraken::OTPRequiredError,
      "unknown" => Provider::Kraken::ApiError }
    cases.each do |message, classification|
      Provider::Kraken.expects(:get).returns(response({ error: [ "#{message} private-key private-response" ], result: nil }.to_json))
      error = assert_raises(classification) { @provider.get_asset_info_snapshot }
      refute_includes error.message, "private-key"
      refute_includes error.message, "private-response"
      assert_nil error.cause
    end
    Provider::Kraken.expects(:get).returns(response("private-key invalid JSON"))
    error = assert_raises(Provider::Kraken::ApiError) { @provider.get_asset_info_snapshot }
    assert_nil error.cause
    refute_includes error.message, "private-key"
    Provider::Kraken.expects(:get).raises(SocketError, "private-key remote detail")
    error = assert_raises(Provider::Kraken::ApiError) { @provider.get_asset_info_snapshot }
    assert_nil error.cause
    refute_includes error.message, "private-key"
  end

  private
    def response(body)
      OpenStruct.new(code: 200, body: body)
    end
end
