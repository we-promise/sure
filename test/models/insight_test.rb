require "test_helper"

class InsightTest < ActiveSupport::TestCase
  test "mark_read! transitions active to read and sets read_at" do
    insight = insights(:spending_anomaly_dining)
    assert insight.active?
    assert_nil insight.read_at

    insight.mark_read!

    assert insight.read?
    assert_not_nil insight.read_at
  end

  test "mark_read! is a no-op when already read" do
    insight = insights(:net_worth_milestone)
    assert insight.read?
    original_read_at = insight.read_at

    insight.mark_read!

    assert_equal original_read_at, insight.reload.read_at
  end

  test "dismiss! transitions to dismissed and sets dismissed_at" do
    insight = insights(:spending_anomaly_dining)
    assert insight.active?

    insight.dismiss!

    assert insight.dismissed?
    assert_not_nil insight.dismissed_at
  end

  test "visible scope excludes dismissed insights" do
    dismissed = insights(:dismissed_insight)
    assert_not Insight.visible.include?(dismissed)
  end

  test "visible scope includes active and read insights" do
    active = insights(:spending_anomaly_dining)
    read   = insights(:net_worth_milestone)

    assert Insight.visible.include?(active)
    assert Insight.visible.include?(read)
  end

  test "ordered scope places high priority before medium before low" do
    high_insight = insights(:cash_flow_warning)      # high
    medium_insight = insights(:spending_anomaly_dining)  # medium

    ordered = Insight.where(family: families(:dylan_family)).visible.ordered
    high_idx   = ordered.index(high_insight)
    medium_idx = ordered.index(medium_insight)

    assert_not_nil high_idx
    assert_not_nil medium_idx
    assert high_idx < medium_idx
  end

  test "dedup_key uniqueness is enforced per family" do
    original = insights(:spending_anomaly_dining)

    duplicate = Insight.new(
      family:       original.family,
      insight_type: original.insight_type,
      priority:     "low",
      status:       "active",
      title:        "Duplicate",
      body:         "Duplicate body",
      metadata:     {},
      currency:     "USD",
      dedup_key:    original.dedup_key,
      generated_at: Time.current
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "for_dashboard scope returns at most 3 visible insights" do
    assert Insight.for_dashboard.count <= 3
  end
end
