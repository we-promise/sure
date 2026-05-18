class Insight::Generators::SpendingAnomalyGenerator < Insight::Generator
  BASELINE_MONTHS = 3
  MIN_BASELINE = 50
  DEVIATION_THRESHOLD = 0.25
  HIGH_PRIORITY_DEVIATION = 0.50

  def generate
    return [] if family.accounts.visible.none?

    current_period = Period.current_month_for(family)
    pace = pace_factor(current_period)

    current_by_category = parent_category_totals(current_period)
    baseline_by_category = baseline_category_totals

    current_by_category.filter_map do |category_id, current|
      category = current[:category]
      baseline = baseline_by_category[category_id]
      next if baseline.nil? || baseline < MIN_BASELINE

      projected = (current[:total] * pace).round(2)
      deviation = (projected - baseline) / baseline.to_f
      next if deviation.abs < DEVIATION_THRESHOLD

      direction = deviation.positive? ? "above" : "below"
      priority = deviation.abs >= HIGH_PRIORITY_DEVIATION ? "high" : "medium"
      pct = (deviation.abs * 100).round

      metadata = {
        "category_id" => category_id,
        "category_name" => category.name,
        "baseline" => baseline.round(2),
        "projected" => projected,
        "deviation_pct" => pct,
        "direction" => direction
      }

      fallback = "Your projected #{category.name} spending this month is #{format_money(projected)}, " \
                 "about #{pct}% #{direction} your #{BASELINE_MONTHS}-month average of #{format_money(baseline)}."

      body = generate_body(
        facts: {
          signal: "spending_anomaly",
          category: category.name,
          projected_month_spend: format_money(projected),
          three_month_average: format_money(baseline),
          percent_change: pct,
          direction: direction
        },
        fallback: fallback
      )

      GeneratedInsight.new(
        insight_type: "spending_anomaly",
        priority: priority,
        title: "#{category.name} spending is #{direction} average",
        body: body,
        metadata: metadata,
        currency: currency,
        period_start: current_period.start_date,
        period_end: current_period.end_date,
        dedup_key: "spending_anomaly:#{category_id}:#{current_period.start_date.strftime('%Y-%m')}"
      )
    end
  end

  private
    def pace_factor(period)
      month_start = period.start_date
      month_end = if family.uses_custom_month_start?
        family.custom_month_end_for(Date.current)
      else
        Date.current.end_of_month
      end

      total_days = (month_end - month_start).to_i + 1
      elapsed_days = (Date.current - month_start).to_i + 1
      return 1.0 if elapsed_days <= 0 || elapsed_days >= total_days

      total_days.to_f / elapsed_days
    end

    def parent_category_totals(period)
      family.income_statement.expense_totals(period: period).category_totals
        .reject { |ct| ct.category.subcategory? }
        .reject { |ct| ct.category.id.nil? }
        .reject { |ct| ct.total.to_f.zero? }
        .each_with_object({}) do |ct, hash|
          hash[ct.category.id] = { category: ct.category, total: ct.total.to_f }
        end
    end

    def baseline_category_totals
      sums = Hash.new(0.0)

      BASELINE_MONTHS.times do |i|
        month = Date.current.beginning_of_month - (i + 1).months
        period = Period.custom(start_date: month.beginning_of_month, end_date: month.end_of_month)

        family.income_statement.expense_totals(period: period).category_totals
          .reject { |ct| ct.category.subcategory? }
          .reject { |ct| ct.category.id.nil? }
          .each { |ct| sums[ct.category.id] += ct.total.to_f }
      end

      sums.transform_values { |total| total / BASELINE_MONTHS }
    end
end
