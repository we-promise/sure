require "test_helper"

# `judge` against OpenRouter's decisions gateway (the `:jev_openrouter` preset), through the full
# Sure path: routed plan -> Ai::Generation -> judge transport -> RubyLLM OpenRouter provider ->
# /api/alpha/decisions -> typed choice answer back. It uses Parallel's free decision model as a
# stand-in for the wire format: it isn't TypeSafe's Jev, so its confidence isn't calibrated.
#
# Replayed from test/vcr_cassettes/ai/openrouter_jev/, recorded with
# RECORD_CASSETTES=1 and OPENROUTER_LIVE_API_KEY set, or run live with
# AI_LIVE=1. With neither, it's skipped, saying so. The recording asks for the free
# `parallel/decisions-fast:free` decisions model; that's the JEV_MODEL to set when reproducing
# the call through Sure's own env configuration.
class AiOpenrouterJevLiveTest < ActiveSupport::TestCase
  KEY = "OPENROUTER_LIVE_API_KEY".freeze
  MODEL = "parallel/decisions-fast:free".freeze

  # Both decisions requests share a URI; match on the state so each recorded answer is replayed
  # for the transaction it answered, whichever way the batch orders the calls.
  STATE_MATCHER = lambda do |recorded, played|
    begin
      JSON.parse(recorded.body.to_s)["state"] == JSON.parse(played.body.to_s)["state"]
    rescue JSON::ParserError
      false
    end
  end

  setup do
    @family = families(:dylan_family)
  end

  test "decisions recordings match on the transaction state, not only the shared URI" do
    request = ->(description) do
      VCR::Request.new(:post, "https://openrouter.ai/api/alpha/decisions",
                       { model: MODEL, state: { description: } }.to_json, {})
    end

    assert STATE_MATCHER.call(request.("STARBUCKS 1234 SEATTLE"), request.("STARBUCKS 1234 SEATTLE"))
    assert_not STATE_MATCHER.call(request.("STARBUCKS 1234 SEATTLE"), request.("ACME CORP PAYROLL"))
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

    result = with_ai_cassette("openrouter_jev", "judge_categorize", match: [ :method, :uri, STATE_MATCHER ]) {
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

    result = with_ai_cassette("openrouter_jev", "judge_categorize", match: [ :method, :uri, STATE_MATCHER ]) {
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
