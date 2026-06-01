require "test_helper"

class GenerateInsightsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    Setting.stubs(:insights_enabled).returns(true)
  end

  test "performs without error for a family with no accounts" do
    empty_family = families(:empty)
    assert_nothing_raised do
      GenerateInsightsJob.new.perform(family_id: empty_family.id)
    end
  end

  test "performs without error when family_id is missing" do
    assert_nothing_raised do
      GenerateInsightsJob.new.perform(family_id: "nonexistent-id")
    end
  end

  test "does not create duplicate insights on repeated runs" do
    # Stub all generators to return a deterministic insight so we don't need real data
    fixed_insight = Insight::Generator::GeneratedInsight.new(
      insight_type: "net_worth_milestone",
      priority:     "high",
      title:        "Net worth milestone",
      body:         "You hit a milestone.",
      metadata:     { "milestone" => 100_000 },
      currency:     @family.currency,
      period_start: 30.days.ago.to_date,
      period_end:   Date.current,
      dedup_key:    "net_worth_milestone:test:#{Date.current.strftime("%Y-%m")}"
    )

    Insight::GeneratorRegistry.stubs(:generate_for).returns([ fixed_insight ])

    assert_difference "@family.insights.count", 1 do
      GenerateInsightsJob.new.perform(family_id: @family.id)
    end

    # Second run — same dedup_key — should upsert, not create a new record
    assert_no_difference "@family.insights.count" do
      GenerateInsightsJob.new.perform(family_id: @family.id)
    end
  end

  test "updates existing insight body and generated_at on repeated runs" do
    dedup = "net_worth_milestone:update_test:#{Date.current.strftime("%Y-%m")}"
    old_insight = @family.insights.create!(
      insight_type: "net_worth_milestone",
      priority:     "high",
      status:       "active",
      title:        "Old title",
      body:         "Old body",
      metadata:     { "milestone" => 50_000 },
      currency:     @family.currency,
      period_start: 30.days.ago.to_date,
      period_end:   Date.current,
      dedup_key:    dedup,
      generated_at: 1.day.ago
    )

    updated_insight = Insight::Generator::GeneratedInsight.new(
      insight_type: "net_worth_milestone",
      priority:     "high",
      title:        "New title",
      body:         "New body",
      metadata:     { "milestone" => 100_000 },
      currency:     @family.currency,
      period_start: 30.days.ago.to_date,
      period_end:   Date.current,
      dedup_key:    dedup
    )

    Insight::GeneratorRegistry.stubs(:generate_for).returns([ updated_insight ])
    GenerateInsightsJob.new.perform(family_id: @family.id)

    refreshed = @family.insights.find_by(dedup_key: dedup)
    assert_equal "New title", refreshed.title
    assert_equal "New body", refreshed.body
    assert refreshed.generated_at > old_insight.generated_at, "generated_at should be updated on upsert"
  end
end
