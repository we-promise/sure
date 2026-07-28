require "test_helper"

class InsightsHelperTest < ActionView::TestCase
  test "positive types render success regardless of priority" do
    insight = build_insight("net_worth_milestone", priority: "high", metadata: { "milestone" => 500_000 })

    assert_equal :positive, insight_sentiment(insight)
    assert_equal "success", insight_icon_color(insight)
  end

  test "savings rate improvement is positive even at high priority" do
    insight = build_insight(
      "savings_rate_change",
      priority: "high",
      metadata: { "current_rate" => 32.5, "previous_rate" => 20.1 }
    )

    assert_equal :positive, insight_sentiment(insight)
    assert_equal "success", insight_icon_color(insight)
  end

  test "savings rate drop warns without going red" do
    insight = build_insight(
      "savings_rate_change",
      priority: "high",
      metadata: { "current_rate" => -5.4, "previous_rate" => 45.2 }
    )

    assert_equal :warning, insight_sentiment(insight)
    assert_equal "warning", insight_icon_color(insight)
  end

  test "spending anomaly direction decides sentiment" do
    above = build_insight("spending_anomaly", metadata: { "direction" => "above" })
    below = build_insight("spending_anomaly", metadata: { "direction" => "below" })

    assert_equal :warning, insight_sentiment(above)
    assert_equal :positive, insight_sentiment(below)
  end

  test "only a projected-negative balance renders destructive" do
    negative = build_insight("cash_flow_warning", priority: "high", metadata: { "negative" => true })
    low = build_insight("cash_flow_warning", priority: "medium", metadata: { "negative" => false })

    assert_equal "destructive", insight_icon_color(negative)
    assert_equal "warning", insight_icon_color(low)
  end

  test "informational types stay neutral" do
    %w[subscription_audit idle_cash].each do |type|
      assert_equal :neutral, insight_sentiment(build_insight(type))
      assert_equal "default", insight_icon_color(build_insight(type))
    end
  end

  test "rows written before the metadata shape change degrade safely" do
    stale = build_insight("cash_flow_warning", priority: "high", metadata: { "projected_low_amount" => 320.0 })

    assert_equal :warning, insight_sentiment(stale)
  end

  test "meta line shows the type and a month-aligned period as the month name" do
    insight = build_insight(
      "savings_rate_change",
      period_start: Date.new(Date.current.year, 6, 1),
      period_end: Date.new(Date.current.year, 6, 30)
    )

    assert_equal "Savings rate · June", insight_meta_line(insight)
  end

  test "meta line labels a forward-looking window as next N days" do
    insight = build_insight(
      "cash_flow_warning",
      period_start: Date.current,
      period_end: Date.current + 30
    )

    assert_equal "Cash flow · Next 30 days", insight_meta_line(insight)
  end

  test "meta line falls back to the subject when there is no period" do
    insight = build_insight("idle_cash", facts: { "account" => "Emergency fund" })

    assert_equal "Idle cash · Emergency fund", insight_meta_line(insight)
  end

  test "key figure comes from facts and hides for rows without them" do
    with_facts = build_insight("idle_cash", facts: { "balance" => "$28,400.00", "idle_days" => 60 })
    without_facts = build_insight("idle_cash")

    assert_equal "$28,400.00", insight_key_figure(with_facts).first
    assert_nil insight_key_figure(without_facts)
  end

  test "action link resolves the stored subject and disappears when it cannot" do
    account = families(:dylan_family).accounts.visible.first
    resolvable = build_insight("idle_cash", metadata: { "account_id" => account.id })
    dangling = build_insight("idle_cash", metadata: { "account_id" => SecureRandom.uuid })

    assert_equal account_path(account), insight_action(resolvable)[:href]
    assert_nil insight_action(dangling)
  end

  private
    def build_insight(insight_type, priority: "medium", metadata: {}, facts: {}, period_start: nil, period_end: nil)
      Insight.new(
        family: families(:dylan_family),
        insight_type: insight_type,
        priority: priority,
        status: "active",
        title: "t",
        body: "b",
        metadata: metadata,
        facts: facts,
        period_start: period_start,
        period_end: period_end,
        dedup_key: "#{insight_type}:test"
      )
    end
end
