require "test_helper"

class Insight::CopyTest < ActiveSupport::TestCase
  test "falls back to stored prose when facts cannot fill the template" do
    insight = insights(:spending_anomaly_dining)

    copy = Insight::Copy.new(insight)

    assert_equal insight.title, copy.title
    assert_equal insight.body, copy.body
  end

  test "renders Danish title and body from facts for a savings-rate insight" do
    insight = Insight.new(
      insight_type: "savings_rate_change",
      title: "Your savings rate improved in July",
      body: "You saved 14.0% of your income in July, up 110.7 percentage points from −96.7% the month before.",
      facts: { "month" => "July", "current_rate" => "14.0", "previous_rate" => "−96.7", "change_pp" => 110.7 },
      metadata: { "current_rate" => 14.0, "previous_rate" => -96.7 },
      period_start: Date.new(2026, 7, 1),
      period_end: Date.new(2026, 7, 31)
    )

    I18n.with_locale(:da) do
      copy = Insight::Copy.new(insight)

      assert_equal "Din opsparingsrate steg i juli", copy.title
      assert_match(/Du sparede 14.0% af din indtægt i juli/, copy.body)
    end
  end

  test "renders Danish spending-anomaly copy including the category name" do
    insight = Insight.new(
      insight_type: "spending_anomaly",
      title: "Boligforbedring spending is trending down",
      body: "You're on pace to spend 39,95 kr. on Boligforbedring this month, about 98% less than your recent monthly average of 1.741,46 kr.",
      facts: {
        "category" => "Boligforbedring",
        "deviation_pct" => 98,
        "projected_spend" => "39,95 kr.",
        "baseline_spend" => "1.741,46 kr."
      },
      metadata: { "direction" => "below" }
    )

    I18n.with_locale(:da) do
      copy = Insight::Copy.new(insight)

      assert_equal "Forbrug i Boligforbedring er faldende", copy.title
      assert_match(/på vej til at bruge 39,95 kr. på Boligforbedring/, copy.body)
    end
  end

  test "renders Danish cash-flow warning from type and metadata" do
    insight = Insight.new(
      insight_type: "cash_flow_warning",
      title: "Your cash balance may go negative",
      body: "Based on your upcoming recurring transactions and typical spending, your cash balance could fall to -182.897,86 kr. around 2026-09-20.",
      facts: { "projected_low" => "-182.897,86 kr.", "projected_low_date" => "2026-09-20" },
      metadata: { "negative" => true }
    )

    I18n.with_locale(:da) do
      copy = Insight::Copy.new(insight)

      assert_equal "Din kontantsaldo kan blive negativ", copy.title
      assert_match(/falde til -182.897,86 kr. omkring 2026-09-20/, copy.body)
    end
  end
end
