# frozen_string_literal: true

require "test_helper"

class Onchain::AvalancheCChainAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::AVALANCHE_C)
  end

  test "accepts a 0x address and rejects anything else without a request" do
    assert @adapter.valid_address?(ADDRESS)

    [ "", "0x1234", "P-avax1g32kvaugnx4tfkks33yqy93w5kavuvwtqfel52", "#{ADDRESS}00" ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "a checksummed address and its lowercase form are one address" do
    assert_equal ADDRESS.downcase, @adapter.canonical_address(" #{ADDRESS} ")
  end

  test "the balance is the native AVAX quantity, with no history" do
    stub_rpc("eth_getBalance" => "0x1bc16d674ec80000")

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "AVAX", asset.symbol
    assert_equal BigDecimal("2"), asset.quantity
    assert_empty snapshot.movements
  end

  test "a non-numeric balance is not read as a number" do
    stub_rpc("eth_getBalance" => "0xnope")

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a balance that is not a 0x hex quantity is refused rather than parsed" do
    [ "1000000000000000000", "-0x1" ].each do |balance|
      stub_rpc("eth_getBalance" => balance)

      assert_raises(Onchain::Chains::UnreachableError, balance) { @adapter.fetch_snapshot(ADDRESS) }
    end
  end

  # Every EVM network shares this address shape: answering yes for any
  # well-formed address would make every Ethereum wallet ambiguous.
  test "an address with no AVAX is not detected, in one request" do
    probe = stub_rpc("eth_getBalance" => "0x0")

    assert_equal false, @adapter.has_activity?(ADDRESS)
    assert_requested probe, times: 1
  end

  test "a funded address is detected in one request" do
    probe = stub_rpc("eth_getBalance" => "0x1")

    assert @adapter.has_activity?(ADDRESS)
    assert_requested probe, times: 1
  end

  test "a node that could not answer is not read as an empty address" do
    stub_request(:post, Provider::AvalancheCChain.base_url).to_timeout

    assert_nil @adapter.has_activity?(ADDRESS)
  end

  test "a throttled node is reported as rate limited" do
    stub_request(:post, Provider::AvalancheCChain.base_url).to_return(status: 429)

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an RPC error that is a bare string is reported as unreachable" do
    stub_request(:post, Provider::AvalancheCChain.base_url)
      .to_return(status: 200, body: { "error" => "temporarily unavailable" }.to_json, headers: json_headers)

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an RPC error is reported as unreachable" do
    stub_request(:post, Provider::AvalancheCChain.base_url)
      .to_return(status: 200, body: { "error" => { "message" => "boom" } }.to_json, headers: json_headers)

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end

    # One stub for the endpoint, answering by JSON-RPC method name.
    def stub_rpc(results)
      stub_request(:post, Provider::AvalancheCChain.base_url).to_return do |request|
        result = results.fetch(JSON.parse(request.body)["method"])
        { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => result }.to_json, headers: json_headers }
      end
    end
end
