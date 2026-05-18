require "test_helper"

class GenerateInsightsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @empty_family = families(:empty)
  end

  test "does not raise for a family with no accounts" do
    assert_nothing_raised do
      GenerateInsightsJob.new.perform(family_id: @empty_family.id)
    end
  end

  test "creates insights for a family from generated results" do
    generated = [
      Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in Checking",
        body: "You have idle cash sitting around.",
        metadata: { "account_name" => "Checking", "balance" => 9000.0 },
        currency: "USD",
        period_start: Date.current,
        period_end: Date.current,
        dedup_key: "idle_cash:test:#{Date.current.strftime('%Y-%m')}"
      )
    ]

    Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(generated)

    assert_difference -> { @family.insights.count }, 1 do
      GenerateInsightsJob.new.perform(family_id: @family.id)
    end

    insight = @family.insights.find_by(dedup_key: generated.first.dedup_key)
    assert_equal "idle_cash", insight.insight_type
    assert insight.status_active?
  end

  test "running twice does not duplicate insights (upsert)" do
    generated = [
      Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in Checking",
        body: "You have idle cash sitting around.",
        metadata: { "balance" => 9000.0 },
        currency: "USD",
        period_start: Date.current,
        period_end: Date.current,
        dedup_key: "idle_cash:test:#{Date.current.strftime('%Y-%m')}"
      )
    ]

    Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(generated)

    GenerateInsightsJob.new.perform(family_id: @family.id)

    assert_no_difference -> { @family.insights.count } do
      GenerateInsightsJob.new.perform(family_id: @family.id)
    end
  end
end
