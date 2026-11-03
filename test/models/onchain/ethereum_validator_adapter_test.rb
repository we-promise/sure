# frozen_string_literal: true

require "test_helper"

class Onchain::EthereumValidatorAdapterTest < ActiveSupport::TestCase
  PUBKEY = "0x#{"A1d1" * 24}"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::ETHEREUM_VALIDATOR)
  end

  test "accepts a BLS public key and nothing an EVM chain would" do
    assert @adapter.valid_address?(PUBKEY)

    [ "", "1", "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "#{PUBKEY}00" ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "no EVM chain claims a validator public key" do
    assert_equal [ Onchain::Chains::ETHEREUM_VALIDATOR ], Onchain::Chains.matching(PUBKEY).map(&:key)
  end

  test "a public key and its lowercase form are one validator" do
    assert_equal PUBKEY.downcase, @adapter.canonical_address(" #{PUBKEY} ")
  end

  test "the balance is in Gwei, not wei" do
    stub_validator(status: 200, body: { "data" => { "index" => "1", "balance" => "32049991519", "status" => "active_ongoing" } })

    snapshot = @adapter.fetch_snapshot(PUBKEY)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "ETH", asset.symbol
    assert_equal BigDecimal("32.049991519"), asset.quantity
    assert_empty snapshot.movements
  end

  test "an unknown validator is refused, not read as zero" do
    stub_validator(status: 404, body: { "code" => 404, "message" => "NOT_FOUND: unknown validator" })

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(PUBKEY) }
    assert_not_kind_of Onchain::Chains::UnreachableError, error
  end

  test "a key the node rejects as malformed is refused, not reported as unreachable" do
    stub_validator(status: 400, body: { "code" => 400, "message" => "Invalid validator ID" })

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(PUBKEY) }
    assert_not_kind_of Onchain::Chains::UnreachableError, error
  end

  test "a validator without a balance is not read as zero" do
    stub_validator(status: 200, body: { "data" => { "index" => "1", "status" => "active_ongoing" } })

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(PUBKEY)
    end
  end

  test "a response without data is reported as unreachable" do
    stub_validator(status: 200, body: {})

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(PUBKEY)
    end
  end

  test "a throttled node is reported as rate limited" do
    stub_validator(status: 429, body: {})

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(PUBKEY)
    end
  end

  private
    def stub_validator(status:, body:)
      stub_request(:get, "#{Provider::EthereumBeaconApi.base_url}/eth/v1/beacon/states/head/validators/#{PUBKEY}")
        .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end
end
