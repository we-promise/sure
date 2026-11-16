# Tracks how much of a typical month's income is already spoken for by
# recurring commitments, and speaks up when that share rises RISE_THRESHOLD_PP
# points against six months ago, or crosses CEILING_PCT.
#
#   ratio = monthly equivalent of the recurring outflows in force
#           / median monthly income over the six complete months before
#
# The median, not the mean, so a month with extra pay (a bonus, a thirteenth
# payment) does not make commitments look smaller than they are.
#
# Outflows are expense series plus recurring payments into a loan. Payments
# into a credit card are left out: they repay spending that is already counted
# on the card, much of it not fixed at all. Both sides of the ratio read only
# accounts every active member can see, since the feed is shared and the body
# names series and income.
#
# The figure six months ago is rebuilt from the series in force on that date,
# priced through their price history, so a series swapped for another of the
# same cost is not a rise. Cadence changes are not tracked: every series is
# normalised at its current cadence.
class Insight::Generators::FixedCommitmentsRatioGenerator < Insight::Generator
  produces "fixed_commitments_ratio"

  RISE_THRESHOLD_PP = 5
  CEILING_PCT = 50
  WINDOW_MONTHS = 6
  MAX_CONTRIBUTORS = 3

  def generate
    return [] if family.recurring_transactions_disabled?

    current_income = median_monthly_income(months_back: 0)
    previous_income = median_monthly_income(months_back: WINDOW_MONTHS)
    return [] unless current_income.positive? && previous_income.positive?

    current = monthly_commitments(series.select(&:active?))
    previous = monthly_commitments(series.select { |recurring| in_force_on_reference_date?(recurring) }, on: reference_date)
    return [] if current.empty? || previous.empty?

    current_total = current.values.sum
    previous_total = previous.values.sum
    current_ratio = current_total / current_income * 100
    previous_ratio = previous_total / previous_income * 100
    rise_pp = current_ratio - previous_ratio
    crossed_ceiling = previous_ratio < CEILING_PCT && current_ratio >= CEILING_PCT
    return [] unless rise_pp >= RISE_THRESHOLD_PP || crossed_ceiling

    # The share of the rise that comes from income alone: the same commitments
    # measured against the new income instead of the old.
    income_part_pp = current_total / current_income * 100 - current_total / previous_income * 100
    variant = current_ratio >= CEILING_PCT ? "over_half" : "up"

    [
      build_insight(
        insight_type: "fixed_commitments_ratio",
        priority: variant == "over_half" ? "high" : "medium",
        title: I18n.t("insights.titles.fixed_commitments_ratio.#{variant}"),
        template_key: "fixed_commitments_ratio",
        facts: {
          current_ratio: decimal_fact(current_ratio),
          previous_ratio: decimal_fact(previous_ratio),
          commitments: format_money(current_total),
          income: format_money(current_income),
          explanation: explanation(current, previous, previous_income: previous_income, current_income: current_income,
                                                      mention_income: income_part_pp >= rise_pp / 2)
        },
        # Banded by the rise threshold: the reference window rolls every month
        # and averaged amounts nudge with every charge, so only a climb into the
        # next band is a new insight. One key for the family, so an acknowledged
        # rise is not raised again next month with the same numbers.
        metadata: {
          current_band: (current_ratio / RISE_THRESHOLD_PP).floor * RISE_THRESHOLD_PP
        },
        period: income_window(months_back: 0),
        dedup_key: "fixed_commitments_ratio"
      )
    ]
  end

  private
    # The last day of the earlier income window, so the comparison moves once
    # a month with the windows rather than every night.
    def reference_date
      @reference_date ||= income_window(months_back: WINDOW_MONTHS).end_date
    end

    def shared_accounts
      family.accounts.visible.accessible_by_all_active_members
    end

    def income_statement
      @income_statement ||= IncomeStatement.new(family, accounts: shared_accounts)
    end

    # Every outflow series that was ever confirmed. Suggestions were never in force.
    def series
      @series ||= family.recurring_transactions
        .where.not(status: :suggested)
        .obligations(%w[Loan])
        .within_accounts(shared_accounts)
        .includes(:merchant, :recurrence_rules, :recurring_price_changes)
        .to_a
    end

    def in_force_on_reference_date?(recurring)
      return false if started_after_reference_date?(recurring)
      return true if recurring.active?

      (recurring.cancelled_on || recurring.last_occurrence_date) >= reference_date
    end

    # Only a start Sure actually saw counts as new. A series known before the
    # reference date was in force then. One confirmed since is traced back
    # through its earliest occurrence or a past first due date, but history is
    # backfilled for a limited window only, so a start within one cycle of
    # where that window could begin is the edge of the history, not the start
    # of the commitment. A series declared going forward, with nothing before
    # its creation, is assumed to have been there all along.
    def started_after_reference_date?(recurring)
      created_on = recurring.created_at.to_date
      return false if created_on <= reference_date

      first_seen = [ first_due_on[recurring.id], recurring.anchor_date ].compact.min
      return false if first_seen.nil? || first_seen >= created_on

      history_floor = [ reference_date, created_on << RecurringTransaction::Pipeline::FIRST_RUN_BACKFILL_MONTHS ].max
      first_seen > history_floor + cycle_days(recurring)
    end

    def cycle_days(recurring)
      (365.25 / recurring.schedule.occurrences_per_year).round
    end

    def first_due_on
      @first_due_on ||= family.recurring_occurrences
        .where(recurring_transaction_id: series.map(&:id))
        .group(:recurring_transaction_id)
        .minimum(:due_on)
    end

    # { series => monthly amount in the family currency }. A series with no
    # exchange rate is left out, as on the Bills page.
    def monthly_commitments(series_list, on: nil)
      series_list.each_with_object({}) do |recurring, amounts|
        amounts[recurring] = recurring.monthly_equivalent_amount(on: on).exchange_to(family.currency).amount
      rescue Money::ConversionError
        next
      end
    end

    # The complete months ending `months_back` months before last month.
    def income_window(months_back:)
      last_month = Period.last_month_for(family)
      Period.custom(start_date: last_month.start_date << (months_back + WINDOW_MONTHS - 1),
                    end_date: last_month.end_date << months_back)
    end

    def median_monthly_income(months_back:)
      window_start = income_window(months_back: months_back).start_date
      totals = (0...WINDOW_MONTHS).map do |offset|
        start_date = window_start >> offset
        period = Period.custom(start_date: start_date, end_date: (start_date >> 1) - 1)
        income_statement.income_totals(period: period).total.to_d
      end
      median(totals)
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    end

    # The series that grew the most (new ones count in full), and the drop in
    # income when it drove at least half the rise. A series that replaced
    # another is compared with the one it replaced.
    def explanation(current, previous, previous_income:, current_income:, mention_income:)
      predecessors = previous.keys.select(&:replaced_by_id).index_by(&:replaced_by_id)
      contributors = current.filter_map do |recurring, amount|
        before = previous[recurring] || previous[predecessors[recurring.id]]
        added = amount - (before || 0)
        [ recurring, added, before ] if added.positive?
      end

      sentences = []
      if contributors.any?
        names = contributors.max_by(MAX_CONTRIBUTORS) { |_, added, _| added }.map do |recurring, added, before|
          I18n.t("insights.fixed_commitments_ratio.contributor.#{before ? "raised" : "new"}",
                 name: recurring.display_name, amount: format_money(added))
        end
        sentences << I18n.t("insights.fixed_commitments_ratio.contributors", list: names.to_sentence)
      end
      if mention_income
        sentences << I18n.t("insights.fixed_commitments_ratio.income_fell",
                            previous_income: format_money(previous_income), current_income: format_money(current_income))
      end
      sentences.join(" ")
    end
end
