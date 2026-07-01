require "test_helper"

class GenerateInsightsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "without args enqueues one job per family" do
    assert_enqueued_jobs Family.count, only: GenerateInsightsJob do
      GenerateInsightsJob.perform_now
    end
  end

  test "does nothing for an unknown family" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: SecureRandom.uuid)
    end
  end

  test "does nothing for a family without accounts" do
    family = families(:empty)

    assert_no_difference "Insight.count" do
      GenerateInsightsJob.perform_now(family_id: family.id)
    end
  end

  test "runs all generators against real family data without raising" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "creates an active insight with a body from a generated insight" do
    stub_generated([ generated_insight ])

    assert_difference "@family.insights.count", 1 do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    assert_equal "active", insight.status
    assert_equal "idle_cash", insight.insight_type
    assert insight.body.present?
    assert_equal 5000.0, insight.metadata["balance"]
  end

  test "re-running with unchanged numbers does not duplicate or rewrite" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_body = insight.body

    assert_no_difference "@family.insights.count" do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    assert_equal original_body, insight.reload.body
  end

  test "dismissed insight stays dismissed when numbers are unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.dismiss!

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.dismissed?
  end

  test "dismissed insight reactivates when numbers change materially" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.dismiss!

    stub_generated([ generated_insight(balance: 9000.0) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_equal 9000.0, insight.metadata["balance"]
  end

  private
    def stub_generated(generated_insights)
      Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(generated_insights)
    end

    def generated_insight(balance: 5000.0)
      Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in Test Checking",
        template_key: "idle_cash",
        facts: { account: "Test Checking", balance: "$#{balance.to_i}", idle_days: 60 },
        metadata: { account_id: "test-account", balance: balance },
        currency: "USD",
        period_start: nil,
        period_end: nil,
        dedup_key: "idle_cash:test-account:2026-07"
      )
    end
end
