# frozen_string_literal: true

require "test_helper"

class Onchain::AssetBudgetTest < ActiveSupport::TestCase
  test "defaults to a reviewable number of tokens" do
    assert_equal Onchain::AssetBudget::DEFAULT_TOKENS, Onchain::AssetBudget.tokens
  end

  test "is configurable and clamped rather than able to reach zero" do
    with_env("500") { assert_equal 500, Onchain::AssetBudget.tokens }
    with_env("0") { assert_equal Onchain::AssetBudget::DEFAULT_TOKENS, Onchain::AssetBudget.tokens }
    with_env("nope") { assert_equal Onchain::AssetBudget::DEFAULT_TOKENS, Onchain::AssetBudget.tokens }
    with_env("999999") { assert_equal Onchain::AssetBudget::MAX_TOKENS, Onchain::AssetBudget.tokens }
  end

  private
    def with_env(value)
      previous = ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"]
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = value
      yield
    ensure
      ENV["ONCHAIN_MAX_TOKENS_PER_ADDRESS"] = previous
    end
end
