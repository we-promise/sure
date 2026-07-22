require "test_helper"
require "ostruct"

class Insight::BodyWriterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "returns nil when nobody in the family has AI enabled" do
    @family.users.update_all(ai_enabled: false)
    Provider::Registry.expects(:preferred_llm_provider).never

    assert_nil Insight::BodyWriter.new(@family).write(generated_insight)
  end

  test "uses LLM prose when a user has opted in and a provider is configured" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(FakeLlmProvider.new("Narrated body."))

    body = Insight::BodyWriter.new(@family).write(generated_insight)

    assert_equal "Narrated body.", body
  end

  test "instructs the LLM to write in the language of the generation locale" do
    provider = FakeLlmProvider.new("Corps narré.")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    I18n.with_locale(:fr) do
      Insight::BodyWriter.new(@family).write(generated_insight)
    end

    assert_includes provider.last_instructions, "Write in French."
  end

  test "hands the LLM facts localized for the generation locale" do
    provider = FakeLlmProvider.new("Corps narré.")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    with_float_fact = generated_insight.with(facts: generated_insight.facts.merge(change_pp: 12.8))

    I18n.with_locale(:fr) do
      Insight::BodyWriter.new(@family).write(with_float_fact)
    end

    assert_includes provider.last_prompt, "12,8"
  end

  test "returns nil and captures a debug log when the LLM call fails" do
    provider = FakeLlmProvider.new("unused")
    provider.stubs(:chat_response).raises(StandardError.new("boom"))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    body = :unset
    assert_difference "DebugLogEntry.count", 1 do
      body = Insight::BodyWriter.new(@family).write(generated_insight)
    end

    assert_nil body
  end

  test "every template key interpolates with its generator's facts" do
    %i[en fr].each do |locale|
      I18n.with_locale(locale) do
        TEMPLATE_FACTS.each do |template_key, facts|
          body = I18n.t!("insights.templates.#{template_key}", **Insight.localize_facts(facts))

          assert body.present?, "[#{locale}] insights.templates.#{template_key} produced a blank body"
        end
      end
    end
  end

  private
    # One representative facts hash per template a generator can emit, shaped
    # like the raw values generators store (floats, ISO dates, money facts).
    # Keeps the i18n templates honest: a renamed key or interpolation raises
    # here instead of shipping "translation missing" in production.
    MONEY = ->(amount) { { amount: amount, currency: "USD" } }

    TEMPLATE_FACTS = {
      "spending_anomaly.above" => { category: "Food & Drink", deviation_pct: 38, projected_spend: MONEY.(612.00), baseline_spend: MONEY.(443.00) },
      "spending_anomaly.below" => { category: "Food & Drink", deviation_pct: 30, projected_spend: MONEY.(310.00), baseline_spend: MONEY.(443.00) },
      "cash_flow_warning.low" => { projected_low: MONEY.(320.00), projected_low_date: "2026-07-28", current_balance: MONEY.(1200.00), horizon_days: 30 },
      "cash_flow_warning.negative" => { projected_low: MONEY.(-412.00), projected_low_date: "2026-07-28", current_balance: MONEY.(800.00), horizon_days: 30 },
      "net_worth_milestone" => { milestone: MONEY.(500_000), net_worth: MONEY.(878_578.56) },
      "subscription_audit" => { name: "Netflix", amount: MONEY.(15.49), days_overdue: 48, expected_on: "2026-05-24" },
      "savings_rate_change.up" => { month: "June", current_rate: 32.5, previous_rate: 20.1, change_pp: 12.4 },
      "savings_rate_change.down" => { month: "June", current_rate: 12.1, previous_rate: 45.2, change_pp: 33.1 },
      "savings_rate_change.down_negative" => { month: "June", current_rate: -5.4, previous_rate: 45.2, change_pp: 50.6 },
      "idle_cash" => { account: "Emergency fund", balance: MONEY.(28_400.00), idle_days: 60 },
      "budget_at_risk.over" => { categories: "Food & Drink and Travel", count: 2, budget_spent_pct: 84 },
      "budget_at_risk.near" => { categories: "Shopping", count: 1, budget_spent_pct: 72 },
      "budget_on_track" => { spent: MONEY.(2948.00), budgeted: MONEY.(5200.00), budget_spent_pct: 57 }
    }.freeze

    class FakeLlmProvider
      attr_reader :last_prompt, :last_instructions

      def self.effective_model
        "fake-model"
      end

      def initialize(body)
        @body = body
      end

      def chat_response(prompt, **kwargs)
        @last_prompt = prompt
        @last_instructions = kwargs[:instructions]
        OpenStruct.new(
          success?: true,
          data: OpenStruct.new(messages: [ OpenStruct.new(id: "1", output_text: @body) ])
        )
      end
    end

    def generated_insight
      @generated_insight ||= Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in Emergency fund",
        template_key: "idle_cash",
        facts: { account: "Emergency fund", balance: MONEY.(28_400.00), idle_days: 60 },
        metadata: { account_id: "acct", balance: 28_400.0 },
        currency: "USD",
        period_start: nil,
        period_end: nil,
        dedup_key: "idle_cash:acct:2026-07"
      )
    end
end
