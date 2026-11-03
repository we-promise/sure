# frozen_string_literal: true

require "test_helper"

class Onchain::SolanaStakeAdapterTest < ActiveSupport::TestCase
  ADDRESS = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  SYSTEM_PROGRAM_ID = "11111111111111111111111111111111"
  # Written out rather than read from the constant, so a mistyped constant fails here.
  STAKE_PROGRAM_ID = "Stake11111111111111111111111111111111111111"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::SOLANA_STAKE)
  end

  test "accepts a Base58 account address" do
    assert @adapter.valid_address?(ADDRESS)
    assert_not @adapter.valid_address?("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
  end

  test "a stake account's lamports are its SOL, with no history" do
    stub_account(owner: STAKE_PROGRAM_ID, lamports: 5_002_282_880)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "SOL", asset.symbol
    assert_equal BigDecimal("5.00228288"), asset.quantity
    assert_empty snapshot.movements
  end

  test "an ordinary wallet is refused rather than read as a stake account" do
    stub_account(owner: SYSTEM_PROGRAM_ID, lamports: 1_000_000_000)

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(ADDRESS) }
    assert_match "not a Solana stake account", error.message
  end

  # jsonParsed has no parser for a plain wallet, so its data comes back as a
  # [payload, "base64"] array rather than an object.
  test "an ordinary wallet with unparsed data is refused as not a stake account" do
    stub_rpc("value" => { "owner" => SYSTEM_PROGRAM_ID, "lamports" => 1_000_000_000, "data" => [ "", "base64" ] })

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(ADDRESS) }
    assert_match "not a Solana stake account", error.message
  end

  test "an account without an owner is reported as unreachable, not as a wallet" do
    stub_rpc("value" => { "lamports" => 1_000_000_000 })

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a missing or negative lamport balance is not read as a balance" do
    [ nil, "5", -1 ].each do |lamports|
      stub_rpc("value" => { "owner" => STAKE_PROGRAM_ID, "lamports" => lamports })

      assert_raises(Onchain::Chains::UnreachableError, lamports.inspect) { @adapter.fetch_snapshot(ADDRESS) }
    end
  end

  test "a response without a value is reported as unreachable, not as a missing account" do
    stub_request(:post, Provider::SolanaRpc.url)
      .to_return(status: 200, body: { "result" => nil }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an account that does not exist is refused" do
    stub_rpc("value" => nil)

    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "is left out of auto-detection, so a Solana wallet resolves without a probe" do
    candidates = OnchainWalletItem.new.matching_chain_adapters(ADDRESS).map { |definition, _| definition.key }

    assert_equal [ Onchain::Chains::SOLANA ], candidates
  end

  private
    def stub_account(owner:, lamports:)
      stub_rpc("value" => { "owner" => owner, "lamports" => lamports, "data" => { "program" => "stake" } })
    end

    def stub_rpc(result)
      stub_request(:post, Provider::SolanaRpc.url)
        .with(body: hash_including("method" => "getAccountInfo"))
        .to_return(status: 200, body: { "result" => result }.to_json, headers: { "Content-Type" => "application/json" })
    end
end
