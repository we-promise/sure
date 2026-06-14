# frozen_string_literal: true

require "test_helper"

class Provider::SolanaRpcTest < ActiveSupport::TestCase
  test "validates base58 Solana addresses" do
    provider = Provider::SolanaRpc.new
    assert provider.valid_address?("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
    assert_not provider.valid_address?("0xnot-solana")
  end

  test "get_native_balance returns lamports" do
    provider = Provider::SolanaRpc.new
    provider.stubs(:rpc).with("getBalance", anything).returns({ "value" => 1_500_000_000 })

    assert_equal "1500000000", provider.get_native_balance("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
  end

  test "get_token_balances maps known mints to symbols" do
    provider = Provider::SolanaRpc.new
    provider.stubs(:rpc).with("getTokenAccountsByOwner", anything).returns(
      "value" => [
        { "account" => { "data" => { "parsed" => { "info" => {
          "mint" => "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
          "tokenAmount" => { "amount" => "80000000", "decimals" => 6 }
        } } } } }
      ]
    )

    balances = provider.get_token_balances("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
    usdt = balances.find { |b| b[:symbol] == "USDT" }
    assert_equal BigDecimal("80"), usdt[:ui_amount]
    assert_equal "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", usdt[:mint]
  end
end
