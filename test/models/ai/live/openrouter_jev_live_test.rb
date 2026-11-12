require "test_helper"

# `judge` against OpenRouter's decisions gateway (the `:jev_openrouter` preset
# added in PR #4892), with OpenRouter's free decision model. Exercises the
# full Sure path: routed plan -> Ai::Generation -> judge transport -> RubyLLM
# OpenRouter provider -> /api/alpha/decisions -> typed choice answer back.
#
# Replayed from test/vcr_cassettes/ai/openrouter_jev/, recorded with
# RECORD_CASSETTES=1 and OPENROUTER_LIVE_API_KEY set, or run live with
# AI_LIVE=1. With neither, it's skipped, saying so.
class AiOpenrouterJevLiveTest < ActiveSupport::TestCase
  KEY = "OPENROUTER_LIVE_API_KEY".freeze
  MODEL = "parallel/decisions-fast:free".freeze

  setup do
    @family = families(:dylan_family)
  end

  test "openrouter jev: categorize answers through the OpenRouter decisions preset" do
    skip "no cassette ai/openrouter_jev/judge_categorize; record with RECORD_CASSETTES=1 and #{KEY} set" unless ai_cassette_available?("openrouter_jev", "judge_categorize", key: KEY)

    categories = [
      { id: "cat_food", name: "Food & Drink", is_subcategory: false, parent_id: nil },
      { id: "cat_coffee", name: "Coffee Shops", is_subcategory: true, parent_id: "cat_food" },
      { id: "cat_salary", name: "Salary", is_subcategory: false, parent_id: nil },
      { id: "cat_groceries", name: "Groceries", is_subcategory: false, parent_id: nil }
    ]
    transactions = [
      { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS 1234 SEATTLE", merchant: "Starbucks" },
      { id: "txn_2", amount: 2500, classification: "income", description: "ACME CORP PAYROLL", merchant: nil }
    ]
    generation = Ai::Generations::CategorizeTransactions.new(transactions:, categories:, family: @family)

    result = with_ai_cassette("openrouter_jev", "judge_categorize", match: %i[method uri]) {
      generation.call(plan:)
    }

    assert result.success?, result.error&.message
    assert result.route.judge?
    assert_equal %w[txn_1 txn_2], result.value[:categorizations].map { _1[:transaction_id] }.sort
  end

  test "openrouter jev: the answers are one of the asked categories when accepted" do
    skip "no cassette ai/openrouter_jev/judge_categorize; record with RECORD_CASSETTES=1 and #{KEY} set" unless ai_cassette_available?("openrouter_jev", "judge_categorize", key: KEY)

    categories = [
      { id: "cat_food", name: "Food & Drink", is_subcategory: false, parent_id: nil },
      { id: "cat_coffee", name: "Coffee Shops", is_subcategory: true, parent_id: "cat_food" },
      { id: "cat_salary", name: "Salary", is_subcategory: false, parent_id: nil },
      { id: "cat_groceries", name: "Groceries", is_subcategory: false, parent_id: nil }
    ]
    accepted = categories.map { _1[:name] }
    transactions = [
      { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS 1234 SEATTLE", merchant: "Starbucks" },
      { id: "txn_2", amount: 2500, classification: "income", description: "ACME CORP PAYROLL", merchant: nil }
    ]
    generation = Ai::Generations::CategorizeTransactions.new(transactions:, categories:, family: @family)

    result = with_ai_cassette("openrouter_jev", "judge_categorize", match: %i[method uri]) {
      generation.call(plan:)
    }

    assert result.success?
    assert (result.value[:categorizations] || []).all? { _1[:category_name].nil? || accepted.include?(_1[:category_name]) }
  end

  private
    def plan(api_key: ENV[KEY].presence || "recorded")
      endpoint = Ai::Config::Endpoint.new(name: "jev", protocol: :jev, preset: :jev_openrouter,
                                          base_url: "https://openrouter.ai/api/v1", api_key:, max_retries: 2)
      model = Ai::Config::Model.new(endpoint:, name: MODEL, capabilities: %i[judge calibrated_confidence])
      Ai::Plan.new(feature: :categorize, lane: :background, routes: [ Ai::Route.new(feature: :categorize, model:) ])
    end
end
