require "test_helper"

class InsightTest < ActiveSupport::TestCase
  setup do
    @insight = insights(:spending_anomaly_dining)
  end

  test "mark_read! transitions state and sets read_at" do
    assert @insight.status_active?
    assert_nil @insight.read_at

    @insight.mark_read!

    assert @insight.status_read?
    assert_not_nil @insight.read_at
  end

  test "mark_read! is a no-op once dismissed" do
    @insight.dismiss!

    @insight.mark_read!

    assert @insight.status_dismissed?
  end

  test "dismiss! removes insight from visible scope" do
    assert_includes Insight.visible, @insight

    @insight.dismiss!

    assert_not_includes Insight.visible, @insight
    assert_not_nil @insight.dismissed_at
  end

  test "dedup_key is unique within the same family and type" do
    assert_raises ActiveRecord::RecordInvalid do
      Insight.create!(
        family: @insight.family,
        insight_type: @insight.insight_type,
        priority: "low",
        status: "active",
        title: "Duplicate",
        body: "Duplicate body",
        currency: "USD",
        generated_at: Time.current,
        dedup_key: @insight.dedup_key
      )
    end
  end
end
