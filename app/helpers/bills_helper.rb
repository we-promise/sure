module BillsHelper
  # A bill's next due date reads "Oct 5" when it falls this year and gains the
  # year otherwise, so an every-2-years bill never shows "Sep 1" for a date
  # that is years out. Same rule as Period#label. Payment dates are historical
  # and always carry the year instead.
  def bills_upcoming_date(date)
    l(date, format: date.year == Date.current.year ? :short : :short_with_year)
  end

  # The date a bill row is about. The subline leads with it below @lg, and the
  # rail prints it from there up (bills_rail_date). Snooze-aware, like
  # derived_state and Next up.
  def bills_row_date(occurrence)
    date = occurrence.effective_due_on
    date == Date.current ? t("bills.row_today") : bills_upcoming_date(date)
  end

  # One-shot AI features (smart-fill, smart-configure) need both the user's
  # consent AND a resolvable LLM provider -- an unconfigured self-hosted
  # install renders no AI affordances at all, following the Rules registry's
  # conditional-executor precedent.
  def bills_one_shot_ai_available?
    Current.user&.ai_enabled? && Provider::Registry.preferred_llm_provider.present?
  end

  # Pay-period markers keyed by the id of the FIRST occurrence inside each
  # period, so the section template can drop a marker between groups without
  # pre-bucketing the rows. Each marker carries its period and the summed
  # obligations due inside it. Dated like the rail, so a snoozed row counts
  # toward the period it sits in.
  def bills_pay_period_markers(occurrences, pay_periods)
    return {} if pay_periods.blank?

    seen = Set.new
    occurrences.each_with_object({}) do |occurrence, markers|
      index = pay_periods.index { |p| occurrence.effective_due_on.between?(p.starts_on, p.ends_on) }
      next unless index && seen.add?(index)

      period = pay_periods[index]
      markers[occurrence.id] = {
        period: period,
        due_total: occurrences.select { |o| o.effective_due_on.between?(period.starts_on, period.ends_on) }
                              .sum { |o| o.resolved_expected_amount.abs }
      }
    end
  end

  # The month bar reads paid | overdue | still to come. Overdue money is a
  # subset of what remains, so the slices are derived rather than three
  # independent totals.
  def bills_month_progress(paid:, remaining:, overdue:)
    paid = paid.to_f
    remaining = remaining.to_f
    total = paid + remaining

    paid_pct = total.positive? ? (paid / total * 100) : 0
    overdue_pct = total.positive? ? ([ overdue.to_f, remaining ].min / total * 100) : 0

    {
      total: total,
      paid_pct: paid_pct,
      overdue_pct: overdue_pct,
      upcoming_pct: [ 100 - paid_pct - overdue_pct, 0 ].max
    }
  end

  # What the matcher has learned from manual corrections, prepared for display:
  # Allocator#learn_from_manual_attach! writes both values and until they were
  # surfaced the bill quietly widened what it would match without saying so.
  def bills_matcher_hints(series)
    {
      aliases: Array(series.matcher_hints["name_aliases"]).compact_blank,
      learned_pct: series.matcher_hints["learned_tolerance_pct"].to_f
    }
  end

  # The paycheck plan split into what the page renders: the leading no-income
  # bridge window (reported above the timeline, never inside it), the real
  # periods, and which of the two bridge states applies -- short earns the
  # warning, covered-with-items earns the quiet strip.
  def paycheck_plan_sections(plan)
    return {} if plan.blank?

    bridge = plan.find(&:bridge?)

    {
      bridge: bridge,
      periods: plan.reject(&:bridge?),
      shortfall: bridge&.short? ? bridge : nil,
      bridge_note: bridge && !bridge.short? && bridge.items.any? ? bridge : nil
    }
  end

  # Which bills a transaction paid, prepared for the transaction drawer.
  # Preview-gated with the rest of the bills surface: bill links would
  # dead-end for users without the flag.
  def entry_bill_allocations(entry)
    return [] unless preview_features_enabled?

    entry.recurring_allocations
         .includes(recurring_occurrence: :recurring_transaction)
         .reject { |allocation| allocation.recurring_occurrence.nil? }
  end

  # The paycheck split into `[key, percent]` pairs; the caller owns the colours.
  # A short period gets two segments (covered / short) rather than three, since
  # there is no safe slice to draw.
  def paycheck_allocation_segments(period)
    return [] unless period.income.positive?

    if period.short?
      normalize_segments([
        [ :covered, period.income ],
        [ :short, period.shortfall ]
      ], period.obligation_total)
    else
      normalize_segments([
        [ :due, period.due_total ],
        [ :reserved, period.reserved_total ],
        [ :safe, period.remaining ]
      ], period.income)
    end
  end

  # Percentages summing to exactly 100; the last segment absorbs the remainder
  # so a fully allocated bar never leaves a rounding sliver.
  def normalize_segments(parts, total)
    return [] unless total.positive?

    present = parts.reject { |_key, amount| amount.round(2).zero? }
    return [] if present.empty?

    running = 0
    present.each_with_index.map do |(key, amount), index|
      percent = if index == present.size - 1
        (100 - running).round(2)
      else
        ((amount / total) * 100).round(2).tap { |value| running += value }
      end

      [ key, percent ]
    end
  end

  # The bar in words, in the same terms the card states in text.
  def paycheck_allocation_aria(period, currency)
    if period.short?
      t("bills.paycheck.allocation_aria_short",
        income: format_money(Money.new(period.income, currency)),
        short: format_money(Money.new(period.shortfall, currency)))
    else
      t("bills.paycheck.allocation_aria",
        income: format_money(Money.new(period.income, currency)),
        due: format_money(Money.new(period.due_total, currency)),
        reserved: format_money(Money.new(period.reserved_total, currency)),
        safe: format_money(Money.new(period.remaining, currency)))
    end
  end

  # Named by the income that opens it: a declared series can be a pension or an
  # invoice, so "paycheck" would be an assumption.
  def paycheck_period_heading(period)
    date = l(period.starts_on, format: :short)

    return t("bills.paycheck.before_next_paycheck", date: l(period.ends_on + 1, format: :short)) if period.bridge?

    "#{date}#{paycheck_period_source(period)}"
  end

  # The trailing half of the heading, so the date carries the visual weight.
  def paycheck_period_source(period)
    return "" if period.bridge?

    case period.income_sources.size
    when 0 then ""
    when 1 then t("bills.paycheck.period_source", source: period.income_sources.first)
    else t("bills.paycheck.period_source_multiple", count: period.income_sources.size)
    end
  end

  # The pay schedule in one line: who pays, how often, when next, how much. Two
  # sources landing on one day are counted, never summed under one name.
  def paycheck_income_headline(next_income)
    occurrences = next_income[:occurrences]
    single = occurrences.one? ? occurrences.first.recurring_transaction : nil

    parts = [
      single ? single.display_name : t("bills.paycheck.income_source_count", count: occurrences.size),
      single ? frequency_label(single) : nil,
      t("bills.paycheck.next_on", date: l(next_income[:date], format: :short)),
      next_income[:total] ? format_money(next_income[:total]) : nil
    ]

    parts.compact.join(" · ")
  end

  # Why an income series is listed but not planned around.
  def paycheck_income_excluded_reason(series)
    return t("bills.paycheck.income_paused") unless series.active?

    t("bills.paycheck.income_detected")
  end

  # Leads with the relative distance, which is what tells you whether to act, and
  # keeps the absolute date alongside it for anything further out than a few days.
  #
  # Relative wording is also the safer default: the app runs in UTC while users do
  # not, so a bare calendar date can read as off-by-one for part of every day.
  def bills_due_label(bill)
    days = (bill.next_due_date - Date.current).to_i
    date = l(bill.next_due_date, format: :short)

    if days.negative?
      t("bills.due_label.overdue", count: days.abs, date: date)
    elsif days.zero?
      t("bills.due_label.today")
    else
      t("bills.due_label.upcoming", count: days, date: date)
    end
  end

  # Which account the charge lands on. Worth showing only when it tells the rows
  # apart: on a single-account family it repeated the same name down every line,
  # which is nineteen copies of a fact carrying no information. The bill's
  # drawer names the account regardless, so nothing is lost when it is quiet
  # here.
  def bills_paid_from_label(bill)
    return if bill.account.blank?
    return unless bills_span_multiple_accounts?

    t("bills.paid_from", account: bill.account.name)
  end

  # Autopay is a state, not a task, so it reads on the bill's own line rather
  # than in the slot where the row keeps its verb. A paused bill isn't
  # charging, so it doesn't claim autopay.
  def bills_autopay_label(bill)
    t("recurring_transactions.pay_action.autopay") if bill.autopay? && bill.active?
  end

  # Memoized so this costs one query per request rather than one per row.
  def bills_span_multiple_accounts?
    return @bills_span_multiple_accounts if defined?(@bills_span_multiple_accounts)

    @bills_span_multiple_accounts =
      Current.family.recurring_transactions.where.not(account_id: nil)
             .distinct.count(:account_id) > 1
  end

  # The occurrence-level twin of bills_due_label: relative-first, snooze-aware.
  def occurrence_due_label(occurrence)
    due = occurrence.effective_due_on
    days = (due - Date.current).to_i
    date = bills_upcoming_date(due)

    # A settled cycle is not late. This label only ever looked at dates, so a
    # bill paid three weeks after its due date reported "Overdue by 20 days"
    # directly beside its own "$11.99 of $11.99 paid" total. Once a cycle is
    # closed the only useful fact left is when it had been due.
    return t("bills.due_label.settled", date: date) unless occurrence.scheduled?

    # Nobody is paying a bill that isn't active, so its leftover isn't late.
    # The label leads with the bill's status instead, as its page does.
    series = occurrence.recurring_transaction
    unless series.active?
      return safe_join([ t("recurring_transactions.status.#{series.status}"), t("bills.due_label.due_since", date: date) ], " · ")
    end

    # Overdue is the occurrence's own judgement, not a sign test on the date.
    # RecurringOccurrence#derived_state only calls a cycle overdue once its
    # grace period has run out, and every other surface honours that: the
    # overview files a bill inside its grace under This month, and get_bills
    # reports state "due". This label read the raw date and printed "Overdue by
    # 1 day" on the same bill, in the secondary colour, because the surrounding
    # tone check asks overdue? and got false. The screen contradicted itself
    # and the assistant at once.
    if occurrence.snoozed_until.present? && occurrence.snoozed_until > occurrence.due_on && days.positive?
      t("bills.due_label.snoozed", date: date)
    elsif occurrence.overdue?
      t("bills.due_label.overdue", count: days.abs, date: date)
    elsif days.zero?
      t("bills.due_label.today")
    elsif days.negative?
      # Past its date but still inside the grace the bill was given.
      t("bills.due_label.due_since", date: date)
    else
      t("bills.due_label.upcoming", count: days, date: date)
    end
  end

  # Short enough for a column in the Next up strip: relative while that still
  # means something, absolute once it does not.
  #
  # There is deliberately no "late" case. The strip only ever holds bills due
  # today or later, because something already past its due date is not part of
  # what is coming up -- it is the thing the list below is for.
  def bills_next_up_date(occurrence)
    case (occurrence.effective_due_on - Date.current).to_i
    when 0 then t("bills.month_pulse.date_today")
    when 1 then t("bills.month_pulse.date_tomorrow")
    else bills_upcoming_date(occurrence.effective_due_on)
    end
  end

  # Why this row needs a look, if it does.
  #
  # Needs attention used to say "Overdue" against every row, which is alarming
  # without being actionable: it names the symptom every row already shares
  # instead of the thing that differs. First true wins, most specific first.
  # Paused leads: nobody is paying that bill, so nothing after it applies.
  # Partial stays bare, because the amount column already says what's left.
  def bills_attention_reason(occurrence, suggestion: nil)
    series = occurrence.recurring_transaction
    return t("bills.attention.paused") unless series.active?
    return t("bills.attention.needs_review") if suggestion.present?
    return t("bills.attention.partial") if occurrence.partially_paid?

    if occurrence.overdue?
      return t("bills.attention.overdue", count: (Date.current - occurrence.effective_due_on).to_i)
    end

    recently_changed = series.recurring_price_changes.any? { |change| change.effective_on >= 30.days.ago.to_date && change.material? }
    t("bills.attention.amount_changed") if recently_changed
  end

  # A paused or dismissed bill's leftover is past its date, but nobody is
  # paying it, so it isn't late: no red on its row, its drawers or its page.
  def bills_overdue?(occurrence)
    occurrence.recurring_transaction.active? && occurrence.overdue?
  end

  # A bill row's one line of context, in the same order in every section. It
  # truncates from the end, so the facts you can most do without come last.
  # The red sits on the reason alone.
  def bills_row_subline(occurrence, suggestion: nil)
    series = occurrence.recurring_transaction
    reason = bills_attention_reason(occurrence, suggestion: suggestion)
    reason = tag.span(reason, class: "text-destructive") if reason && bills_overdue?(occurrence)

    safe_join([
      bills_autopay_label(series),
      reason,
      bills_installment_progress(series),
      (t("bills.debt_payment") if series.transfer?),
      frequency_label(series),
      bills_paid_from_label(series)
    ].compact_blank, " · ")
  end

  # The payment the plan is on, capped at its last: a plan settled in full
  # still lists its final row this month.
  def bills_installment_progress(series)
    done, total = series.installment_progress
    t("bills.installment_progress", done_plus_one: [ done + 1, total ].min, total: total) if total
  end

  # The rail is 56px wide, too narrow for "Jan 03, 2027", which wrapped
  # mid-date. Another year's date puts the year on a line of its own.
  def bills_rail_date(occurrence)
    date = occurrence.effective_due_on
    return bills_row_date(occurrence) if date.year == Date.current.year

    safe_join([ l(date, format: :short), tag.span(date.year, class: "block text-subdued") ])
  end

  # The match score's own components, said in words.
  #
  # Deterministic: every phrase here corresponds to a key the matcher actually
  # wrote, so nothing is inferred and nothing is invented. Works for both
  # callers -- a live candidate scored by Matcher#explain (symbol keys) and a
  # persisted allocation's match_signals (string keys out of jsonb).
  #
  # The account signal is deliberately never rendered. It is a constant 0.10 on
  # every candidate, because identity_matches? has already rejected everything
  # on another account, so "same account" is a reason that never once
  # distinguishes one candidate from another.
  def bills_match_reasons(signals, currency:, expected: nil, actual: nil, due_on: nil, paid_on: nil)
    signals = (signals || {}).symbolize_keys
    reasons = []

    reasons << t("bills.match.same_merchant") if signals[:merchant]
    reasons << t("bills.match.name_matches") if signals[:name]

    # Guarded: the review queue can hold an allocation whose entry has been
    # nullified out from under it, so neither figure is guaranteed.
    if signals[:amount] && expected.present? && actual.present?
      difference = (actual - expected).abs

      reasons << if difference < BigDecimal("0.01")
        t("bills.match.exact_amount")
      else
        t("bills.match.amount_off", amount: format_money(Money.new(difference, currency)))
      end
    end

    if signals[:date] && due_on.present? && paid_on.present?
      days = (paid_on - due_on).to_i

      reasons << if days.zero?
        t("bills.match.due_date")
      elsif days.negative?
        t("bills.match.days_before", count: days.abs)
      else
        t("bills.match.days_after", count: days)
      end
    end

    reasons
  end

  # An amount whose expectation is derived (average strategy, or an observed
  # variance band) is shown as approximate; a fixed declared amount never is.
  def occurrence_amount_estimated?(occurrence)
    return false if occurrence.expected_amount.present?

    series = occurrence.recurring_transaction
    !series.amount_fixed? || series.has_amount_variance?
  end
end
