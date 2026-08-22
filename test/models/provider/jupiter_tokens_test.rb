# frozen_string_literal: true

require "test_helper"

class Provider::JupiterTokensTest < ActiveSupport::TestCase
  USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  SPAM = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"

  test "returns verified tokens and drops everything else" do
    stub_search([
      { "id" => USDC, "symbol" => "USDC", "name" => "USD Coin", "isVerified" => true },
      { "id" => SPAM, "symbol" => "USDC", "name" => "USD Coin", "isVerified" => false }
    ])

    metadata = Provider::JupiterTokens.new.metadata_for([ USDC, SPAM ])

    assert_equal({ symbol: "USDC", name: "USD Coin" }, metadata[USDC])
    assert_nil metadata[SPAM]
  end

  test "asks for every mint in one request" do
    request = stub_search([])

    Provider::JupiterTokens.new.metadata_for([ USDC, SPAM, USDC ])

    assert_requested request, times: 1
    assert_requested :get, /lite-api\.jup\.ag/, query: hash_including({ "query" => "#{USDC},#{SPAM}" })
  end

  test "makes no request when there is nothing to look up" do
    assert_empty Provider::JupiterTokens.new.metadata_for([])
    assert_empty Provider::JupiterTokens.new.metadata_for([ nil, "" ])
    assert_not_requested :get, /lite-api\.jup\.ag/
  end

  test "a token with no symbol is not named" do
    stub_search([ { "id" => SPAM, "symbol" => "", "name" => "Nameless", "isVerified" => true } ])

    assert_empty Provider::JupiterTokens.new.metadata_for([ SPAM ])
  end

  test "raises its own error types so the adapter can degrade" do
    stub_request(:get, /lite-api\.jup\.ag/).to_return(status: 429)
    assert_raises Provider::JupiterTokens::RateLimitError do
      Provider::JupiterTokens.new.metadata_for([ USDC ])
    end

    stub_request(:get, /lite-api\.jup\.ag/).to_return(status: 500)
    assert_raises Provider::JupiterTokens::ApiError do
      Provider::JupiterTokens.new.metadata_for([ USDC ])
    end
  end

  test "a timeout becomes its own error type so the adapter degrades" do
    stub_request(:get, /lite-api\.jup\.ag/).to_timeout

    assert_raises Provider::JupiterTokens::ApiError do
      Provider::JupiterTokens.new.metadata_for([ USDC ])
    end
  end

  private
    def stub_search(tokens)
      stub_request(:get, /lite-api\.jup\.ag/)
        .to_return(status: 200, body: tokens.to_json, headers: { "Content-Type" => "application/json" })
    end
end
