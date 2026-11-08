# frozen_string_literal: true

require "test_helper"

class Onchain::PolkadotAdapterTest < ActiveSupport::TestCase
  ADDRESS = "12KeSVQBwS9AjRA976mnJouSAoQuS5bkWudT367GBEHE8Ls"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::POLKADOT)
  end

  test "accepts a Polkadot address" do
    assert @adapter.valid_address?(ADDRESS)
    assert @adapter.valid_address?(" #{ADDRESS} ")
  end

  test "rejects malformed addresses without making a network call" do
    [
      "",
      "12KeSVQBwS9AjRA976mnJouSAoQuS5bkWudT367GBEHE8L",  # too short
      "12KeSVQBwS9AjRA976mnJouSAoQuS5bkWudT367GBEHE8L0", # Base58 excludes 0
      "5C62W7ELLAAfjCQeBU3me9ykaYomD8XTg2B9Hk6ki6Cm3v58", # generic Substrate prefix
      "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"                # a Bitcoin address
    ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "no other chain claims a Polkadot address" do
    assert_equal [ Onchain::Chains::POLKADOT ], Onchain::Chains.matching(ADDRESS).map(&:key)
  end

  test "an address keeps its case" do
    assert_equal ADDRESS, @adapter.canonical_address(" #{ADDRESS} ")
  end

  test "balance is free plus reserved, with no history" do
    stub_balance(free: "25000000000", reserved: "10000000000")

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "DOT", asset.symbol
    assert_equal 10, asset.decimals
    assert_equal BigDecimal("3.5"), asset.quantity
    assert_empty snapshot.movements
  end

  test "a response without a balance is not read as zero" do
    stub_request(:get, balance_url).to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a non-numeric balance is not read as a number" do
    stub_balance(free: "25000000000oops", reserved: "0")

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an address the node rejects is reported as invalid, not unreachable" do
    stub_request(:get, balance_url).to_return(status: 400)

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(ADDRESS) }
    assert_not_kind_of Onchain::Chains::UnreachableError, error
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("not-an-address")
    end
  end

  test "a timed-out sidecar is reported as unreachable" do
    stub_request(:get, balance_url).to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a sidecar that keeps throttling is reported as rate limited" do
    Provider::PolkadotSidecar.any_instance.stubs(:sleep)
    stub_request(:get, balance_url).to_return(status: 429)

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def balance_url
      "#{Provider::PolkadotSidecar.base_url}/accounts/#{ADDRESS}/balance-info"
    end

    def stub_balance(free:, reserved:)
      stub_request(:get, balance_url).to_return(
        status: 200,
        body: { "tokenSymbol" => "DOT", "free" => free, "reserved" => reserved }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end
end
