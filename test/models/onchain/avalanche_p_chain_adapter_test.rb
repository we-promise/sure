# frozen_string_literal: true

require "test_helper"

class Onchain::AvalanchePChainAdapterTest < ActiveSupport::TestCase
  ADDRESS = "P-avax1g32kvaugnx4tfkks33yqy93w5kavuvwtqfel52"
  BARE_ADDRESS = "avax1g32kvaugnx4tfkks33yqy93w5kavuvwtqfel52"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::AVALANCHE_P)
  end

  test "accepts the P- prefixed form" do
    assert @adapter.valid_address?(ADDRESS)
  end

  # Many wallets/explorers show or export the bare bech32 payload with no
  # chain-context prefix at all - the same data is "X-avax1..." on the
  # X-Chain, so the prefix is a presentation convention, not part of the
  # address itself. Confirmed live: a real user's wallet gave them exactly
  # this form and it was rejected before this fix.
  test "accepts the bare form with no chain prefix" do
    assert @adapter.valid_address?(BARE_ADDRESS)
  end

  test "rejects malformed addresses without making a network call" do
    # WebMock raises on any unstubbed request, so a network call here fails the test.
    [
      "",
      "not-an-address",
      "X-avax1g32kvaugnx4tfkks33yqy93w5kavuvwtqfel52", # the X-Chain's own prefix, not ours
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",     # an EVM (C-Chain) address
      "avax1g32kvaugnx4tfkks33yqy93w5kavuvwtqfel1a"     # bech32 excludes "1" from the data part
    ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  # The "P-" prefix is Avalanche's own chain-alias lookup, not part of the
  # bech32 payload, and the node only registers the uppercase alias "P" - a
  # fully-lowercased "p-avax1..." is rejected by the real RPC with "there is
  # no ID with alias: p" (confirmed live against api.avax.network). So the
  # prefix must stay uppercase in canonical form even though the bech32
  # payload after it is canonically lowercase.
  test "canonicalizes to the P- prefixed (uppercase prefix, lowercase payload) form regardless of input style" do
    assert_equal ADDRESS, @adapter.canonical_address(ADDRESS.upcase)
    assert_equal ADDRESS, @adapter.canonical_address(BARE_ADDRESS.upcase)
    assert_equal ADDRESS, @adapter.canonical_address(" #{BARE_ADDRESS} ")
    assert_equal ADDRESS, @adapter.canonical_address(ADDRESS.downcase)
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("not-an-address")
    end
  end

  test "balance is unlocked UTXOs plus whatever is actively bonded" do
    stub_platform_request("platform.getBalance", { "balance" => "2000000000" })
    stub_platform_request("platform.getStake", { "staked" => "500000000" })

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "AVAX", asset.symbol
    assert_equal BigDecimal("2.5"), asset.quantity
    assert snapshot.history_truncated?
    assert_empty snapshot.movements
  end

  test "a response without a staked amount is not read as zero" do
    stub_platform_request("platform.getBalance", { "balance" => "2000000000" })
    stub_platform_request("platform.getStake", {})

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a throttled node is reported as rate limited" do
    stub_request(:post, Provider::AvalanchePChain.base_url).to_return(status: 429)

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def stub_platform_request(method, result)
      stub_request(:post, Provider::AvalanchePChain.base_url)
        .with(body: ->(body) { JSON.parse(body)["method"] == method })
        .to_return(
          status: 200,
          body: { jsonrpc: "2.0", id: 1, result: result }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
end
