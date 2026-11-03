# frozen_string_literal: true

require "test_helper"

class Onchain::PolygonStakeAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0xF086597e0e155f9e46fbda46d5549697a103ffb4"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::POLYGON_STAKE)
  end

  test "is keyed by an ordinary 0x wallet address, in lowercase" do
    assert @adapter.valid_address?(ADDRESS)
    assert_equal ADDRESS.downcase, @adapter.canonical_address(ADDRESS)
  end

  test "the staked position is summed over every validator, with no history" do
    stub_page(0, [ delegation("103636000000000000000000"), delegation("500000000000000000") ])

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "POL", asset.symbol
    assert_equal BigDecimal("103636.5"), asset.quantity
    assert_empty snapshot.movements
  end

  test "every page of delegations is read, not just the first" do
    full_page = Array.new(Provider::PolygonStakingApi::PAGE_LIMIT) { delegation("1000000000000000000") }
    stub_page(0, full_page)
    stub_page(Provider::PolygonStakingApi::PAGE_LIMIT, [ delegation("1000000000000000000") ])

    quantity = @adapter.fetch_snapshot(ADDRESS).assets.sole.quantity

    assert_equal BigDecimal(Provider::PolygonStakingApi::PAGE_LIMIT + 1), quantity
  end

  test "a page the API capped below the requested size is not taken for the last" do
    stub_page(0, [ delegation("1000000000000000000") ] * 2, applied_limit: 2)
    stub_page(2, [ delegation("1000000000000000000") ], applied_limit: 2)

    assert_equal BigDecimal(3), @adapter.fetch_snapshot(ADDRESS).assets.sole.quantity
  end

  test "delegations that exactly fill every page are read in full" do
    limit = Provider::PolygonStakingApi::PAGE_LIMIT
    pages = Provider::PolygonStakingApi::MAX_PAGES
    pages.times { |page| stub_page(page * limit, Array.new(limit) { delegation("1000000000000000000") }) }
    stub_page(pages * limit, [])

    assert_equal BigDecimal(pages * limit), @adapter.fetch_snapshot(ADDRESS).assets.sole.quantity
  end

  test "more delegations than the page cap fail rather than undercount" do
    limit = Provider::PolygonStakingApi::PAGE_LIMIT
    pages = Provider::PolygonStakingApi::MAX_PAGES
    pages.times { |page| stub_page(page * limit, Array.new(limit) { delegation("1000000000000000000") }) }
    stub_page(pages * limit, [ delegation("1000000000000000000") ])

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a delegation that is not an object is reported as unreachable" do
    stub_page(0, [ nil ])

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "a delegation without a stake is not read as zero" do
    stub_page(0, [ { "bondedValidator" => "1" } ])

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "is left out of auto-detection, so an EVM wallet is not asked about it" do
    candidates = OnchainWalletItem.new.matching_chain_adapters(ADDRESS).map { |definition, _| definition.key }

    assert_includes candidates, Onchain::Chains::ETHEREUM
    assert_not_includes candidates, Onchain::Chains::POLYGON_STAKE
  end

  test "a throttled API is reported as rate limited" do
    stub_request(:get, delegators_url).with(query: hash_including({})).to_return(status: 429)

    assert_raises Onchain::Chains::RateLimitedError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  test "an API that refuses the request is reported as unreachable" do
    stub_request(:get, delegators_url).with(query: hash_including({}))
      .to_return(status: 200, body: { "success" => false, "message" => "bad" }.to_json, headers: json_headers)

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end

    def delegators_url
      "#{Provider::PolygonStakingApi.base_url}/delegators/#{ADDRESS}"
    end

    def delegation(stake)
      { "bondedValidator" => "1", "stake" => stake }
    end

    def stub_page(offset, result, applied_limit: Provider::PolygonStakingApi::PAGE_LIMIT)
      stub_request(:get, delegators_url)
        .with(query: { "limit" => Provider::PolygonStakingApi::PAGE_LIMIT.to_s, "offset" => offset.to_s })
        .to_return(status: 200, body: { "success" => true, "result" => result, "summary" => { "limit" => applied_limit, "offset" => offset } }.to_json, headers: json_headers)
    end
end
