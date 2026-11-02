# frozen_string_literal: true

require "test_helper"

class Onchain::SolanaStakeAdapterTest < ActiveSupport::TestCase
  ADDRESS = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  SYSTEM_PROGRAM_ID = "11111111111111111111111111111111"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::SOLANA_STAKE)
  end

  test "accepts a Base58 account address" do
    assert @adapter.valid_address?(ADDRESS)
    assert_not @adapter.valid_address?("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
  end

  test "a stake account's lamports are its SOL, with no history" do
    stub_account(owner: Provider::SolanaRpc::STAKE_PROGRAM_ID, lamports: 5_002_282_880)

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

  test "an account that does not exist is refused" do
    stub_rpc("value" => nil)

    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "only an account the Stake program owns is detected" do
    stub_account(owner: Provider::SolanaRpc::STAKE_PROGRAM_ID, lamports: 1)
    assert @adapter.has_activity?(ADDRESS)

    stub_account(owner: SYSTEM_PROGRAM_ID, lamports: 1)
    assert_equal false, @adapter.has_activity?(ADDRESS)
  end

  test "a node that could not answer is not read as an empty address" do
    stub_request(:post, Provider::SolanaRpc.url).to_timeout

    assert_nil @adapter.has_activity?(ADDRESS)
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
