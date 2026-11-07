require "test_helper"

# `generate` against real providers (2c plan, step 13): replayed from cassettes under
# test/vcr_cassettes/ai/<preset>/, recorded with RECORD_CASSETTES=1 and the keys in ENV, or run
# live with AI_LIVE=1 (the `ai-live` label). A test with no cassette and no key is skipped,
# saying so, so a fresh checkout stays green.
#
# Anthropic's three models are the check behind decision 7: every current Claude model, the
# ones that refuse a forced tool included, must accept native structured output.
class AiGenerateLiveTest < ActiveSupport::TestCase
  ROUTES = {
    "openai/gpt-4.1-mini" => { key: "OPENAI_ACCESS_TOKEN", protocol: :compatible, preset: :openai, responses_api: true },
    "anthropic/claude-haiku-4-5" => { key: "ANTHROPIC_API_KEY", protocol: :anthropic },
    "anthropic/claude-sonnet-5-5" => { key: "ANTHROPIC_API_KEY", protocol: :anthropic },
    "anthropic/claude-opus-5-5" => { key: "ANTHROPIC_API_KEY", protocol: :anthropic },
    "llama_cpp/qwen3.6-35b-a3b-mtp" => { key: "LLAMA_CPP_API_KEY", protocol: :compatible, json_mode: :auto,
                                         base_url: ENV.fetch("LLAMA_CPP_URL", "http://10.72.200.61:8180/v1"), location: :local }
  }.freeze

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Coffee Shops")
  end

  ROUTES.each do |route_name, spec|
    preset, model_name = route_name.split("/", 2)

    test "#{route_name}: categorize answers in the schema" do
      name = "generate_categorize_#{model_name.parameterize}"
      skip_without(preset, name, spec)

      generation = Ai::Generations::CategorizeTransactions.new(
        transactions: [ { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS 1234 SEATTLE", merchant: nil } ],
        categories: [ { id: @category.id, name: @category.name, is_subcategory: false, parent_id: nil } ], family: @family
      )
      result = with_ai_cassette(preset, name) { generation.call(plan: plan_for(:categorize, preset, model_name, spec)) }

      assert result.success?, result.error&.message
      assert_equal [ "txn_1" ], result.value[:categorizations].map { _1[:transaction_id] }
    end

    test "#{route_name}: bill setup answers in the schema" do
      name = "generate_bill_setup_#{model_name.parameterize}"
      skip_without(preset, name, spec)

      generation = Ai::Generations::SuggestBillSetup.new(
        charges: [ { date: "2026-09-03", amount: "15.49", name: "NETFLIX.COM" }, { date: "2026-10-03", amount: "15.49", name: "NETFLIX.COM" } ],
        categories: [ "Entertainment" ], family: @family
      )
      result = with_ai_cassette(preset, name) { generation.call(plan: plan_for(:bill_setup, preset, model_name, spec)) }

      assert result.success?, result.error&.message
      assert_includes [ nil, *RecurringTransaction::FrequencyPreset::PRESETS ], result.value[:frequency]
    end
  end

  private
    def skip_without(preset, name, spec)
      return if ai_cassette_available?(preset, name, key: spec[:key])

      skip "no cassette ai/#{preset}/#{name}; record with RECORD_CASSETTES=1 and #{spec[:key]} set"
    end

    def plan_for(feature, preset, model_name, spec)
      endpoint = Ai::Config::Endpoint.new(name: preset, api_key: ENV[spec[:key]].presence || "recorded",
                                          **spec.slice(:protocol, :preset, :responses_api, :json_mode, :base_url, :location))
      model = Ai::Config::Model.new(endpoint:, name: model_name, capabilities: %i[structured_output], max_output_tokens: 1024)
      route = Ai::Route.new(feature:, position: 0, model:, prompt: Ai::LegacyEnvConfig.prompt_for(feature, endpoint))
      Ai::Plan.new(feature:, lane: Ai::Routes.fetch(feature)[:lane], routes: [ route ])
    end
end
