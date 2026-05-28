# frozen_string_literal: true

require "test_helper"

class Provider::MempoolSpaceTest < ActiveSupport::TestCase
  test "validates bitcoin address shape" do
    provider = Provider::MempoolSpace.new

    assert provider.valid_address?("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
    refute provider.valid_address?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "raises rate limit errors" do
    stub_request(:get, "https://mempool.space/api/address/bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
      .to_return(status: 429, body: "rate limit")

    assert_raises Provider::MempoolSpace::RateLimitError do
      Provider::MempoolSpace.new.get_address("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
    end
  end
end
