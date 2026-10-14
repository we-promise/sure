# frozen_string_literal: true

require "test_helper"

class Onchain::CosmosAdapterTest < ActiveSupport::TestCase
  ADDRESS = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu"
  MODULE_ADDRESS = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5z5tpwxqergd3c8g7rusqqlvp8l"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::COSMOS)
  end

  test "accepts account and module addresses" do
    [ ADDRESS, MODULE_ADDRESS, ADDRESS.upcase ].each do |address|
      assert @adapter.valid_address?(address), "#{address} should be accepted"
    end
  end

  test "rejects malformed addresses without making a network call" do
    [
      "",
      "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7x",   # too short
      "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xb",  # bech32 excludes b
      "osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu",    # another Cosmos chain
      "cosmosvaloper1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu",
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "no other chain claims a Cosmos address" do
    assert_equal [ Onchain::Chains::COSMOS ], Onchain::Chains.matching(ADDRESS).map(&:key)
  end

  test "an address is canonically lowercase" do
    assert_equal ADDRESS, @adapter.canonical_address(" #{ADDRESS.upcase} ")
  end

  test "balance is spendable plus staked plus unbonding, with no history" do
    stub_balance("1500000")
    stub_delegations([
      { "balance" => { "denom" => "uatom", "amount" => "2000000" } },
      { "balance" => { "denom" => "uatom", "amount" => "250000" } }
    ])
    stub_unbondings([ { "entries" => [ { "balance" => "100000" }, { "balance" => "50000" } ] } ])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "ATOM", asset.symbol
    assert_equal 6, asset.decimals
    assert_equal BigDecimal("3.9"), asset.quantity
    assert_empty snapshot.movements
  end

  test "an empty address is worth zero" do
    stub_balance("0")
    stub_delegations([])
    stub_unbondings([])

    assert_equal 0, @adapter.fetch_snapshot(ADDRESS).assets.sole.quantity
  end

  test "staking spread over several pages is summed" do
    stub_balance("0")
    stub_json(
      "/cosmos/staking/v1beta1/delegations/#{ADDRESS}", { "pagination.limit" => "200" },
      { "delegation_responses" => [ { "balance" => { "denom" => "uatom", "amount" => "1000000" } } ], "pagination" => { "next_key" => "abc" } }
    )
    stub_json(
      "/cosmos/staking/v1beta1/delegations/#{ADDRESS}", { "pagination.limit" => "200", "pagination.key" => "abc" },
      { "delegation_responses" => [ { "balance" => { "denom" => "uatom", "amount" => "2000000" } } ], "pagination" => { "next_key" => nil } }
    )
    stub_unbondings([])

    assert_equal BigDecimal("3"), @adapter.fetch_snapshot(ADDRESS).assets.sole.quantity
  end

  test "a response without a balance is not read as zero" do
    stub_json("/cosmos/bank/v1beta1/balances/#{ADDRESS}/by_denom", { denom: "uatom" }, {})

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a staking entry without a balance is not read as zero" do
    stub_balance("1500000")
    stub_delegations([ { "balance" => { "denom" => "uatom", "amount" => "2000000" } } ])
    stub_unbondings([ { "entries" => [ { "balance" => "100000" }, {} ] } ])

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an address the node rejects is reported as invalid, not unreachable" do
    stub_request(:get, "#{base_url}/cosmos/bank/v1beta1/balances/#{ADDRESS}/by_denom").with(query: { denom: "uatom" }).to_return(status: 400)

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(ADDRESS) }
    assert_not_kind_of Onchain::Chains::UnreachableError, error
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises Onchain::Chains::Error do
      @adapter.fetch_snapshot("not-an-address")
    end
  end

  test "a timed-out node is reported as unreachable" do
    stub_request(:get, "#{base_url}/cosmos/bank/v1beta1/balances/#{ADDRESS}/by_denom").with(query: { denom: "uatom" }).to_timeout

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a node that keeps throttling is reported as rate limited" do
    Provider::CosmosRest.any_instance.stubs(:sleep)
    stub_request(:get, "#{base_url}/cosmos/bank/v1beta1/balances/#{ADDRESS}/by_denom").with(query: { denom: "uatom" }).to_return(status: 429)

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def base_url
      Provider::CosmosRest.base_url
    end

    def stub_balance(amount)
      stub_json("/cosmos/bank/v1beta1/balances/#{ADDRESS}/by_denom", { denom: "uatom" }, { "balance" => { "denom" => "uatom", "amount" => amount } })
    end

    def stub_delegations(responses)
      stub_json("/cosmos/staking/v1beta1/delegations/#{ADDRESS}", { "pagination.limit" => "200" }, { "delegation_responses" => responses })
    end

    def stub_unbondings(responses)
      stub_json("/cosmos/staking/v1beta1/delegators/#{ADDRESS}/unbonding_delegations", { "pagination.limit" => "200" }, { "unbonding_responses" => responses })
    end

    def stub_json(path, query, body)
      stub_request(:get, "#{base_url}#{path}").with(query: query)
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end
end
