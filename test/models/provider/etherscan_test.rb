# frozen_string_literal: true

require "test_helper"

class Provider::EtherscanTest < ActiveSupport::TestCase
  test "validates ethereum address shape" do
    provider = Provider::Etherscan.new(api_key: "key")

    assert provider.valid_address?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
    refute provider.valid_address?("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
  end

  test "returns native balance result" do
    stub_request(:get, "https://api.etherscan.io/v2/api")
      .with(query: hash_including("action" => "balance", "address" => "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"))
      .to_return(status: 200, body: { status: "1", message: "OK", result: "1000000000000000000" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_equal "1000000000000000000", Provider::Etherscan.new(api_key: "key").get_native_balance("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "raises rate limit errors from api payload after exhausting retries" do
    stub_request(:get, "https://api.etherscan.io/v2/api")
      .with(query: hash_including("action" => "balance"))
      .to_return(status: 200, body: { status: "0", message: "NOTOK", result: "Max rate limit reached" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises Provider::Etherscan::RateLimitError do
      Provider::Etherscan.new(api_key: "key", max_retries: 0).get_native_balance("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
    end
  end

  test "retries on rate limit and succeeds" do
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    rate_limited = { status: 200, body: { status: "0", message: "NOTOK", result: "Max rate limit reached" }.to_json, headers: { "Content-Type" => "application/json" } }
    success = { status: 200, body: { status: "1", message: "OK", result: "42" }.to_json, headers: { "Content-Type" => "application/json" } }

    stub_request(:get, "https://api.etherscan.io/v2/api")
      .with(query: hash_including("action" => "balance"))
      .to_return(rate_limited, rate_limited, success)

    provider = Provider::Etherscan.new(api_key: "key", max_retries: 3, retry_base_delay: 0)
    assert_equal "42", provider.get_native_balance(address)
  end
end
