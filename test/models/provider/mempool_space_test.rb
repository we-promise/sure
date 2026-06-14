# frozen_string_literal: true

require "test_helper"

class Provider::MempoolSpaceTest < ActiveSupport::TestCase
  test "validates bitcoin address shape" do
    provider = Provider::MempoolSpace.new

    assert provider.valid_address?("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
    refute provider.valid_address?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "raises rate limit error after exhausting retries" do
    stub_request(:get, "https://mempool.space/api/address/bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
      .to_return(status: 429, body: "rate limit")

    assert_raises Provider::MempoolSpace::RateLimitError do
      Provider::MempoolSpace.new(max_retries: 0).get_address("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
    end
  end

  test "retries on rate limit and succeeds" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    rate_limited = { status: 429, body: "rate limit" }
    success = { status: 200, body: { "chain_stats" => {}, "mempool_stats" => {} }.to_json, headers: { "Content-Type" => "application/json" } }

    stub_request(:get, "https://mempool.space/api/address/#{address}")
      .to_return(rate_limited, rate_limited, success)

    provider = Provider::MempoolSpace.new(max_retries: 3, retry_base_delay: 0)
    result = provider.get_address(address)

    assert_equal({}, result["chain_stats"])
  end

  test "returns address data on success" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    payload = { "chain_stats" => { "funded_txo_sum" => 100_000_000, "spent_txo_sum" => 0 }, "mempool_stats" => {} }

    stub_request(:get, "https://mempool.space/api/address/#{address}")
      .to_return(status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" })

    result = Provider::MempoolSpace.new.get_address(address)

    assert_equal 100_000_000, result["chain_stats"]["funded_txo_sum"]
  end

  test "raises InvalidAddressError on 404" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

    stub_request(:get, "https://mempool.space/api/address/#{address}")
      .to_return(status: 404, body: "not found")

    assert_raises Provider::MempoolSpace::InvalidAddressError do
      Provider::MempoolSpace.new.get_address(address)
    end
  end

  test "paginates transaction fetching" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    page1 = Array.new(25) { |i| { "txid" => "tx_#{i}" } }
    page2 = [ { "txid" => "tx_25" } ]

    stub_request(:get, "https://mempool.space/api/address/#{address}/txs")
      .to_return(status: 200, body: page1.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://mempool.space/api/address/#{address}/txs/chain/tx_24")
      .to_return(status: 200, body: page2.to_json, headers: { "Content-Type" => "application/json" })

    result = Provider::MempoolSpace.new.get_address_txs(address)

    assert_equal 26, result.size
  end
end
