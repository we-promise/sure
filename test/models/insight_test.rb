require "test_helper"

class InsightTest < ActiveSupport::TestCase
  setup do
    @insight = insights(:spending_anomaly_dining)
  end

  test "mark_read! transitions active insight and stamps read_at" do
    assert @insight.active?

    @insight.mark_read!

    assert @insight.reload.read?
    assert @insight.read_at.present?
  end

  test "mark_read! does not touch dismissed insights" do
    @insight.dismiss!

    @insight.mark_read!

    assert @insight.reload.dismissed?
    assert_nil @insight.read_at
  end

  test "dismiss! removes insight from visible scope" do
    assert_includes Insight.visible, @insight

    @insight.dismiss!

    assert_not_includes Insight.visible, @insight
    assert @insight.dismissed_at.present?
  end

  test "duplicate dedup_key within a family is rejected" do
    assert_raises ActiveRecord::RecordInvalid do
      @insight.family.insights.create!(
        insight_type: @insight.insight_type,
        priority: "medium",
        title: "Duplicate",
        body: "Duplicate body",
        dedup_key: @insight.dedup_key
      )
    end
  end

  test "same dedup_key is allowed across families" do
    other_family = families(:empty)

    assert_nothing_raised do
      other_family.insights.create!(
        insight_type: @insight.insight_type,
        priority: "medium",
        title: "Same key, other family",
        body: "Body",
        dedup_key: @insight.dedup_key
      )
    end
  end

  test "ordered puts high priority first, then most recent" do
    high = insights(:cash_flow_warning)

    assert_equal high, Insight.ordered.first
  end

  test "insight_type must be a known type" do
    insight = Insight.new(
      family: families(:empty),
      insight_type: "bogus",
      title: "t",
      body: "b",
      dedup_key: "bogus:key"
    )

    assert_not insight.valid?
    assert insight.errors[:insight_type].any?
  end
end
