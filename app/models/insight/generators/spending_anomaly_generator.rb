# Flags parent categories whose current-month spending pace deviates from
# their average over the previous three full months.
class Insight::Generators::SpendingAnomalyGenerator < Insight::Generator
  produces "spending_anomaly"

  MIN_BASELINE = 50           # ignore categories with a negligible baseline
  MIN_ELAPSED_DAYS = 7        # too early in the month = too noisy to project
  DEVIATION_THRESHOLD_PCT = 25
  HIGH_PRIORITY_PCT = 50
  BASELINE_MONTHS = 3
  MAX_INSIGHTS = 3

  def generate
    period = Period.current_month_for(family)
    elapsed_days = (Date.current - period.start_date).to_i + 1
    return [] if elapsed_days < MIN_ELAPSED_DAYS

    current = category_spend(period)
    return [] if current.empty?

    baseline = baseline_spend(period)
    pace_factor = period.days.to_f / elapsed_days

    anomalies = current.filter_map do |category_id, data|
      baseline_amount = baseline[category_id]
      next unless baseline_amount && baseline_amount >= MIN_BASELINE

      projected = data[:total] * pace_factor
      deviation_pct = (projected - baseline_amount) / baseline_amount * 100
      next if deviation_pct.abs < DEVIATION_THRESHOLD_PCT

      { category_id: category_id, name: data[:name], projected: projected,
        baseline: baseline_amount, deviation_pct: deviation_pct }
    end

    anomalies
      .sort_by { |a| -a[:deviation_pct].abs }
      .first(MAX_INSIGHTS)
      .map { |anomaly| anomaly_insight(anomaly, period) }
  end

  private
    def anomaly_insight(anomaly, period)
      direction = anomaly[:deviation_pct].positive? ? "above" : "below"

      build_insight(
        insight_type: "spending_anomaly",
        priority: anomaly[:deviation_pct].abs >= HIGH_PRIORITY_PCT ? "high" : "medium",
        title: I18n.t("insights.titles.spending_anomaly.#{direction}", category: anomaly[:name]),
        template_key: "spending_anomaly.#{direction}",
        facts: {
          category: anomaly[:name],
          deviation_pct: round(anomaly[:deviation_pct].abs, 0).to_i,
          projected_spend: format_money(anomaly[:projected]),
          baseline_spend: format_money(anomaly[:baseline])
        },
        # The projection moves every night by construction (spend accrues and
        # the pace factor shrinks as the month elapses), so exact amounts here
        # would rewrite the body and resurrect dismissals nightly. Bucket the
        # deviation instead; the display numbers live in `facts` only.
        metadata: {
          category_id: anomaly[:category_id],
          direction: direction,
          deviation_bucket: (round(anomaly[:deviation_pct].abs, 0).to_i / 25) * 25
        },
        period: period,
        dedup_key: "spending_anomaly:#{anomaly[:category_id]}:#{month_token(period.start_date)}"
      )
    end

    # { category_id => { name:, total: } } for persisted parent categories only.
    # Subcategory spend is already rolled into its parent's total, and synthetic
    # categories (uncategorized / other investments) are too noisy to flag.
    def category_spend(period)
      income_statement.expense_totals(period: period).category_totals.each_with_object({}) do |ct, totals|
        next if ct.category.synthetic? || ct.category.parent_id.present?
        next unless ct.total.positive?

        totals[ct.category.id] = { name: ct.category.name, total: ct.total.to_d }
      end
    end

    def baseline_spend(current_period)
      sums = Hash.new { |h, k| h[k] = 0.to_d }

      BASELINE_MONTHS.times do |i|
        start_date = current_period.start_date - (i + 1).months
        month = Period.custom(start_date: start_date, end_date: start_date + 1.month - 1.day)

        category_spend(month).each do |category_id, data|
          sums[category_id] += data[:total]
        end
      end

      sums.transform_values { |total| total / BASELINE_MONTHS }
    end
end
