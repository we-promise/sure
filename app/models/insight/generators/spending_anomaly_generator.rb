# Flags parent categories whose current-month spending pace deviates from
# their average over the previous three full months.
#
# Bills are planned spending. What they already took this month counts once at
# face value and what they still expect this month is added as it stands; only
# the rest is projected at the month's pace. A category is flagged only when
# its spending outside bills moves too, so a bill that changes the month (an
# annual premium, a payment that fell in the previous month) is not a trend.
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
    # The "current month" period ends today rather than at month end, so its own
    # #days is the elapsed count and dividing by it would make the projection a
    # no-op. Take the month's true length from its start date, which is also
    # correct for families on a custom month start.
    month_end = period.start_date + 1.month - 1.day
    pace_factor = (month_end - period.start_date + 1).to_f / elapsed_days
    bills_due = bills_still_due(period.start_date..month_end)

    anomalies = current.filter_map do |category_id, data|
      usual = baseline[category_id]
      next unless usual && usual[:total] >= MIN_BASELINE

      due = bills_due.fetch(category_id, 0)
      projected, deviation_pct, unplanned_deviation_pct = project(data, data[:bills], due, usual, pace_factor)
      next unless significant?(deviation_pct, unplanned_deviation_pct)
      next if deviation_pct.positive? && paid_from_rollover?(category_id, data, due, usual, pace_factor)

      { category_id: category_id, name: data[:name], projected: projected,
        baseline: usual[:total], deviation_pct: deviation_pct }
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

    # Both the whole projection and its unplanned part have to clear the
    # threshold in the same direction.
    def significant?(deviation_pct, unplanned_deviation_pct)
      [ deviation_pct, unplanned_deviation_pct ].all? { |pct| pct.abs >= DEVIATION_THRESHOLD_PCT } &&
        deviation_pct.positive? == unplanned_deviation_pct.positive?
    end

    # [projected, deviation_pct, unplanned_deviation_pct]. `planned` counts
    # once at face value and `due` is added as it stands; only the rest of the
    # month-to-date spend is projected at the month's pace.
    def project(data, planned, due, usual, pace_factor)
      unplanned = (data[:total] - planned) * pace_factor
      projected = planned + due + unplanned
      [
        projected,
        (projected - usual[:total]) / usual[:total] * 100,
        (unplanned - (usual[:total] - usual[:bills])) / usual[:total] * 100
      ]
    end

    # Money saved up in a rollover envelope is there to be spent in a lump.
    # Counted as planned, like a bill, does the rise still stand? The envelope
    # may be the parent's or a ring-fenced subcategory's (Insurance under
    # Home), as long as it isn't overspent. Only the household budget counts.
    def paid_from_rollover?(category_id, data, due, usual, pace_factor)
      return false unless current_budget&.initialized?

      envelopes = current_budget.budget_categories.select do |bc|
        (bc.category_id == category_id || bc.category.parent_id == category_id) &&
          bc.rollover_enabled? && !bc.inherits_parent_budget? && !bc.over_budget?
      end
      saved = envelopes.sum { |bc| drawn_from_savings(bc, pace_factor) }
      return false unless saved.positive?

      planned = [ data[:bills] + saved, data[:total] ].min
      deviation_pct, unplanned_deviation_pct = project(data, planned, due, usual, pace_factor).drop(1)
      !(deviation_pct.positive? && significant?(deviation_pct, unplanned_deviation_pct))
    end

    # What an envelope has spent outside bills beyond its own allocation to
    # date, up to what it carried over: the part that came out of savings.
    # Spending within the month's allocation is ordinary spending, whatever
    # cushion sits behind it. Bills are already planned in `data[:bills]`, and
    # a parent leaves its ring-fenced subcategories to their own envelopes.
    def drawn_from_savings(envelope, pace_factor)
      fenced = envelope.subcategories.reject(&:inherits_parent_budget?)
      spent, allocated = %i[actual_spending budgeted_spending].map do |amount|
        outside_bills(envelope, amount) - fenced.sum { |bc| outside_bills(bc, amount) }
      end

      (spent - allocated.clamp(0, nil) / pace_factor).clamp(0, envelope.rolled_over_amount.to_d)
    end

    def outside_bills(budget_category, amount)
      budget_category.public_send(amount).to_d - budget_category.bills_paid.to_d
    end

    # { category_id => { name:, total:, bills: } } for persisted parent
    # categories only. Subcategory spend is already rolled into its parent's
    # total, and synthetic categories (uncategorized / other investments) are
    # too noisy to flag. `bills` is the part of `total` that paid bills.
    def category_spend(period)
      bills = income_statement.bill_expense_totals(period: period).category_totals.to_h { |ct| [ ct.category.id, ct.total.to_d ] }

      income_statement.expense_totals(period: period).category_totals.each_with_object({}) do |ct, totals|
        next if ct.category.synthetic? || ct.category.parent_id.present?
        next unless ct.total.positive?

        totals[ct.category.id] = { name: ct.category.name, total: ct.total.to_d, bills: bills.fetch(ct.category.id, 0) }
      end
    end

    def baseline_spend(current_period)
      sums = Hash.new { |h, k| h[k] = { total: 0.to_d, bills: 0.to_d } }

      BASELINE_MONTHS.times do |i|
        start_date = current_period.start_date - (i + 1).months
        month = Period.custom(start_date: start_date, end_date: start_date + 1.month - 1.day)

        category_spend(month).each do |category_id, data|
          sums[category_id][:total] += data[:total]
          sums[category_id][:bills] += data[:bills]
        end
      end

      sums.transform_values { |usual| usual.transform_values { |amount| amount / BASELINE_MONTHS } }
    end

    # What bills still expect this month, by parent category, in the family's
    # currency. Filed under the bill's own category, since there is no entry
    # yet to take one from. One with no rate is left out, as unplanned spending
    # would be.
    def bills_still_due(dates)
      parent_ids = family.categories.pluck(:id, :parent_id).to_h

      RecurringOccurrence.open_bills_due(family.id, dates).each_with_object(Hash.new(0.to_d)) do |occurrence, sums|
        category_id = occurrence.recurring_transaction.category_id
        sums[parent_ids[category_id] || category_id] += occurrence.remaining_spending_money.exchange_to(family.currency).amount
      rescue Money::ConversionError
        next
      end
    end
end
