require "test_helper"

# `judge` against a real System One server: OpenCode Zen's free Jev, reached at a
# TypeSafe-style path with its anonymous key (`public`).
# Replayed from test/vcr_cassettes/ai/jev/, recorded with RECORD_CASSETTES=1 and JEV_LIVE_API_KEY
# set, or run live with AI_LIVE=1 (the `ai-live` label). With neither, it's skipped, saying so.
class AiJudgeLiveTest < ActiveSupport::TestCase
  KEY = "JEV_LIVE_API_KEY".freeze
  BASE_URL = ENV.fetch("JEV_LIVE_BASE_URL", "https://opencode.ai/zen")
  MODEL = ENV.fetch("JEV_LIVE_MODEL", "jev-1.13-free")

  setup do
    @family = families(:dylan_family)
  end

  test "jev: categorize answers through the judgement, with calibrated confidence" do
    skip "no cassette ai/jev/judge_categorize; record with RECORD_CASSETTES=1 and #{KEY} set" unless ai_cassette_available?("jev", "judge_categorize", key: KEY)

    categories = [
      { id: "cat_food", name: "Food & Drink", is_subcategory: false, parent_id: nil },
      { id: "cat_coffee", name: "Coffee Shops", is_subcategory: true, parent_id: "cat_food" },
      { id: "cat_salary", name: "Salary", is_subcategory: false, parent_id: nil },
      { id: "cat_transport", name: "Transportation", is_subcategory: false, parent_id: nil }
    ]
    transactions = [
      { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS 1234 SEATTLE", merchant: "Starbucks" },
      { id: "txn_2", amount: 2500, classification: "income", description: "ACME CORP PAYROLL", merchant: nil }
    ]
    generation = Ai::Generations::CategorizeTransactions.new(transactions:, categories:, family: @family)

    # Matched on the body too: the two requests run in parallel, so their order varies.
    result = with_ai_cassette("jev", "judge_categorize", match: %i[method uri body]) { generation.call(plan:) }

    assert result.success?, result.error&.message
    assert result.route.judge?
    answers = result.value[:categorizations].index_by { _1[:transaction_id] }
    assert_equal %w[txn_1 txn_2], answers.keys.sort
    assert_equal "Coffee Shops", answers["txn_1"][:category_name]
    assert_equal "Salary", answers["txn_2"][:category_name]
    answers.each_value { assert_includes 0.0..1.0, _1[:confidence] }
  end

  test "jev: a wrong key is Unauthorized, and not retried" do
    skip "no cassette ai/jev/judge_unauthorized; record with RECORD_CASSETTES=1 and #{KEY} set" unless ai_cassette_available?("jev", "judge_unauthorized", key: KEY)

    generation = Ai::Generations::CategorizeTransactions.new(
      transactions: [ { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS" } ],
      categories: [ { id: "cat_coffee", name: "Coffee Shops", is_subcategory: false, parent_id: nil } ], family: @family
    )

    result = with_ai_cassette("jev", "judge_unauthorized") { generation.call(plan: plan(api_key: "not-a-real-key")) }

    assert_kind_of Ai::Error::Unauthorized, result.error
  end

  private
    def plan(api_key: ENV[KEY].presence || "recorded")
      endpoint = Ai::Config::Endpoint.new(name: "jev", protocol: :jev, preset: :jev, base_url: BASE_URL, api_key:, max_retries: 2)
      model = Ai::Config::Model.new(endpoint:, name: MODEL, capabilities: %i[judge calibrated_confidence])
      Ai::Plan.new(feature: :categorize, lane: :background, routes: [ Ai::Route.new(feature: :categorize, model:) ])
    end
end
