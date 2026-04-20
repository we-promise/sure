# Surfaces categories whose spending is significantly above or below their 3-month rolling average.
# Uses the existing IncomeStatement analytics infrastructure — no custom SQL required.
class Insight::Generators::SpendingAnomalyGenerator < Insight::Generator
  ANOMALY_THRESHOLD  = 0.25  # 25% above/below baseline triggers an insight
  MIN_BASELINE_SPEND = 50    # Ignore tiny categories (noise reduction)

  def generate
    current_period = Period.current_month_for(family)
    baseline_period = Period.custom(
      start_date: current_period.start_date - 3.months,
      end_date:   current_period.start_date - 1.day
    )

    income_stmt = family.income_statement

    baseline_totals = income_stmt.expense_totals(period: baseline_period)
    current_totals  = income_stmt.expense_totals(period: current_period)

    baseline_by_cat = baseline_totals.category_totals.index_by { |ct| ct.category.id }
    current_by_cat  = current_totals.category_totals.index_by  { |ct| ct.category.id }

    # Project partial-month spend to a full-month pace
    elapsed_days = [ (Date.current - current_period.start_date).to_i + 1, 1 ].max
    total_days   = [ (current_period.end_date - current_period.start_date).to_i + 1, 1 ].max
    pace_factor  = total_days.to_f / elapsed_days

    all_ids = (baseline_by_cat.keys + current_by_cat.keys).uniq

    insights = all_ids.filter_map do |cat_id|
      baseline_ct = baseline_by_cat[cat_id]
      current_ct  = current_by_cat[cat_id]

      next unless baseline_ct
      next if baseline_ct.category.subcategory?
      next if baseline_ct.category.synthetic?

      baseline_monthly = (baseline_ct.total.to_f / 3.0).round(2)
      next if baseline_monthly < MIN_BASELINE_SPEND

      current_actual = current_ct&.total.to_f || 0
      current_paced  = (current_actual * pace_factor).round(2)

      change_ratio = (current_paced - baseline_monthly) / baseline_monthly
      next if change_ratio.abs < ANOMALY_THRESHOLD

      category  = baseline_ct.category
      direction = change_ratio > 0 ? "up" : "down"
      pct       = (change_ratio.abs * 100).round(0)
      delta     = (current_paced - baseline_monthly).abs.round(2)

      metadata = {
        "category_id"      => cat_id,
        "category_name"    => category.name,
        "current_amount"   => current_paced,
        "baseline_amount"  => baseline_monthly,
        "percent_change"   => (change_ratio * 100).round(1),
        "direction"        => direction,
        "delta_amount"     => delta
      }

      priority = change_ratio.abs >= 0.50 ? "high" : "medium"

      body = generate_body(
        "#{category.name} spending is #{direction} #{pct}% vs the 3-month average. " \
        "Current pace: #{currency_symbol}#{current_paced}. " \
        "Average: #{currency_symbol}#{baseline_monthly}. " \
        "Difference: #{currency_symbol}#{delta}."
      )

      GeneratedInsight.new(
        insight_type: "spending_anomaly",
        priority:     priority,
        title:        I18n.t("insights.spending_anomaly.title",
                             category: category.name,
                             direction: direction,
                             pct: "#{pct}%"),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: current_period.start_date,
        period_end:   current_period.end_date,
        dedup_key:    "spending_anomaly:#{cat_id}:#{current_period.start_date.strftime("%Y-%m-%d")}"
      )
    end

    insights.sort_by { |i| -i.metadata["percent_change"].abs }.first(3)
  end
end
