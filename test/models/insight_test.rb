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

  test "undismiss! restores a dismissed insight as read, not new" do
    @insight.dismiss!

    @insight.undismiss!

    assert @insight.reload.read?
    assert_nil @insight.dismissed_at
    assert @insight.read_at.present?
    assert_includes Insight.visible, @insight
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

  test "display_title and display_body render live in the viewer's locale" do
    insight = savings_rate_insight

    I18n.with_locale(:en) do
      assert_equal "Your savings rate dropped in June", insight.display_title
      assert_includes insight.display_body, "your savings rate fell to −4.3%"
      assert_includes insight.display_body, "June"
    end

    I18n.with_locale(:fr) do
      assert_equal "Votre taux d'épargne a baissé en juin", insight.display_title
      assert_includes insight.display_body, "−4,3"
      assert_includes insight.display_body, "juin"
    end
  end

  test "display_body prefers stored LLM prose over the template" do
    insight = savings_rate_insight
    insight.body = "Narrated by the LLM."

    assert_equal "Narrated by the LLM.", insight.display_body
  end

  test "rows predating template_key fall back to their stored prose" do
    assert_equal @insight.title, @insight.display_title
    assert_equal @insight.body, @insight.display_body
  end

  test "display_body renders blank instead of a translation-missing string for an unresolved template_key" do
    insight = savings_rate_insight
    insight.template_key = "savings_rate_change.no_longer_exists"

    assert_equal "", insight.display_body
  end

  test "budget_at_risk title pluralizes on the flagged-category count" do
    insight = Insight.new(
      family: families(:dylan_family),
      insight_type: "budget_at_risk",
      title: "stored",
      template_key: "budget_at_risk.over",
      facts: { "categories" => "Food & Drink and Travel", "count" => 2, "budget_spent_pct" => 84 },
      dedup_key: "budget_at_risk:test"
    )

    assert_equal I18n.t("insights.titles.budget_at_risk", count: 2), insight.display_title
  end

  test "localize_fact_value formats floats, ISO dates, and money facts for the locale and passes the rest through" do
    date = Date.new(2026, 7, 28)
    money = { "amount" => 28_400.00, "currency" => "USD" }

    I18n.with_locale(:en) do
      assert_equal "12.8", Insight.localize_fact_value(12.8)
      assert_equal "−4.3", Insight.localize_fact_value(-4.3)
      assert_equal "12", Insight.localize_fact_value(12.0)
      assert_equal I18n.l(date), Insight.localize_fact_value("2026-07-28")
      assert_equal "$28,400.00", Insight.localize_fact_value(money)
    end

    I18n.with_locale(:fr) do
      assert_equal "12,8", Insight.localize_fact_value(12.8)
      assert_equal I18n.l(date), Insight.localize_fact_value("2026-07-28")
      assert_equal "28 400,00 $", Insight.localize_fact_value(money)
    end

    assert_equal 60, Insight.localize_fact_value(60)
    assert_equal "Emergency fund", Insight.localize_fact_value("Emergency fund")
    assert_equal "$500,000", Insight.localize_fact_value({ "amount" => 500_000, "currency" => "USD", "precision" => 0 })
  end

  private
    # month is stored as the generation-locale name on purpose (it feeds the
    # LLM prompt); display re-derives it from period_start, so a June period
    # must render "juin" under :fr even though "June" is stored.
    def savings_rate_insight
      Insight.new(
        family: families(:dylan_family),
        insight_type: "savings_rate_change",
        priority: "high",
        status: "active",
        title: "stored title",
        template_key: "savings_rate_change.down_negative",
        facts: { "month" => "June", "current_rate" => -4.3, "previous_rate" => 8.5, "change_pp" => 12.8 },
        metadata: { "current_rate" => -4.3, "previous_rate" => 8.5 },
        period_start: Date.new(2026, 6, 1),
        period_end: Date.new(2026, 6, 30),
        dedup_key: "savings_rate_change:2026-06"
      )
    end
end
