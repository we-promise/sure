class BillsController < ApplicationController
  include RecurringFeatureGuardable

  # What the All-bills status filter offers: payment state, plus the two
  # lifecycle values people actually use. suggested and inactive are detection
  # plumbing and stay out.
  PAYMENT_FILTERS = %w[overdue due partial paid].freeze
  # Pause stores `inactive`, so the filter has to accept both. `paused` arrives
  # only by import or the v1 API; `ended` only by dismissing a suggestion.
  LIFECYCLE_STATUSES = { "paused" => %w[inactive paused], "ended" => %w[ended] }.freeze
  LIFECYCLE_FILTERS = LIFECYCLE_STATUSES.keys.freeze
  STATUS_FILTERS = (PAYMENT_FILTERS + LIFECYCLE_FILTERS).freeze
  # Enough to answer "what happens next" without becoming a second bill list.
  NEXT_UP_LIMIT = 4
  # Six covers a month of weekly paydays with room for a leading bridge.
  PAY_PERIOD_LIMIT = 6
  before_action :ensure_recurring_enabled

  # The pay-run workspace, built on occurrence rows rather than series
  # projections, so every row has a real due date and payment state.
  def index
    if params[:view] == "subscriptions"
      redirect_to bills_path(view: "all", q: { bill_type: "subscription" })
      return
    end

    @view = %w[all calendar paycheck].include?(params[:view]) ? params[:view] : "overview"

    # An upgraded instance can arrive with series but no occurrence rows,
    # because nothing under the old build ever materialized them. One inline,
    # idempotent generation covers every view. The cache is a cost gate, not
    # correctness -- the none? probe stays authoritative; the guard only stops
    # an all-ended-series family from re-running generation on every GET.
    cache_key = "bills:materialized:#{Current.family.id}"
    if Current.family.recurring_occurrences.none? && !Rails.cache.read(cache_key)
      materialize_missing_occurrences
      Rails.cache.write(cache_key, true, expires_in: 12.hours)
    end

    case @view
    when "all"
      load_all_series
      render :all
      return
    when "calendar"
      load_calendar
      render :calendar
      return
    when "paycheck"
      load_paycheck_plan
      render :paycheck
      return
    end

    occurrences = payable_occurrences
    preload_allocation_sums(occurrences)

    today = Date.current
    month_end = today.end_of_month

    open_occurrences, closed = occurrences.partition(&:scheduled?)
    active_open, @dormant = open_occurrences.partition { |occurrence| occurrence.recurring_transaction.active? }

    @overdue, upcoming = active_open.partition { |occurrence| occurrence.derived_state == :overdue }
    this_month, later = upcoming.partition { |occurrence| occurrence.due_on <= month_end }
    @this_month = this_month.sort_by(&:due_on)
    @overdue = @overdue.sort_by(&:due_on)
    @dormant = @dormant.sort_by(&:due_on)

    # Beyond this month, one row per series: a weekly bill's next six
    # occurrences are not six separate things to think about yet.
    @later = later.group_by(&:recurring_transaction_id)
                  .values
                  .map { |group| group.min_by(&:due_on) }
                  .sort_by(&:due_on)

    @paid_this_month = closed.select { |occurrence| occurrence.paid? && occurrence.due_on >= today.beginning_of_month }
                             .sort_by(&:due_on)

    compute_kpis(today, month_end)

    @month_pay_periods = month_pay_periods(today, month_end)

    @detected_awaiting_review = detected_awaiting_review
    # Fresh detections wait here for confirm/dismiss. Reviewing them is bill
    # work, so the strip lives on this page as well as in Settings.
    # Loaded once: the view asks any?/none? and the partial counts and
    # iterates, which would otherwise be separate queries.
    @suggested_series = accessible_suggested_series.includes(:merchant).order(next_expected_date: :asc).load
    @has_transaction_history = Current.family.entries.where(entryable_type: "Transaction").exists?
    @suggested_allocations = suggested_allocations
    # A row waiting on a match decision offers Review rather than Find.
    # Already loaded for the queue above, so indexing is free.
    @suggestions_by_occurrence = @suggested_allocations.index_by(&:recurring_occurrence_id)
    @notices = collect_notices

    # The month as one chronological list, paid rows in place under a check.
    # Overdue rows are excluded: they get their own section.
    @month_rows = (@this_month + @paid_this_month).sort_by(&:due_on)

    # Next up filters on the DATE, not derived_state: a bill two days late is
    # still :due within its grace period, and nothing already past its due date
    # belongs under "what happens next".
    @month_bill_count = @overdue.size + @month_rows.size
    @next_up = (@this_month + @later)
                 .select { |occurrence| occurrence.effective_due_on >= today }
                 .sort_by(&:effective_due_on)
                 .first(NEXT_UP_LIMIT)
  end

  # One-click detection for a page with nothing on it: run the full pipeline
  # and land back here, where the review strip presents anything found. The
  # flash counts only rows this run created and this user can see -- the
  # pattern total would count refreshes of series that already exist.
  def detect
    before_ids = accessible_suggested_series.pluck(:id)
    # backfill: user-triggered detection always reconstructs history (the
    # backfiller is idempotent). nil means another run holds the family lock.
    result = RecurringTransaction::Pipeline.new(Current.family).run_with_lock!(backfill: true)

    flash[:notice] =
      if result.nil?
        t(".already_running")
      else
        found = accessible_suggested_series.where.not(id: before_ids).count
        found.positive? ? t(".found", count: found) : t(".none_found")
      end

    redirect_to bills_path
  end

  # Revocation for the iCal feed: every previously shared URL stops working.
  def reset_feed_token
    Current.family.reset_bills_feed_token!
    flash[:notice] = t(".done")
    redirect_to bills_path(view: "calendar")
  end

  # One bill's complete story: current state, history, what is coming, cost.
  def show
    @series = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .includes(:merchant)
                     .find(params[:id])

    # A row expansion names the cycle it was opened from; the bill's own page
    # has no cycle in mind and asks the series. Looked up through the series, so
    # an id from another bill resolves to nothing rather than to someone else's
    # occurrence.
    @current_occurrence =
      if params[:occurrence].present?
        @series.recurring_occurrences.find_by(id: params[:occurrence]) || @series.current_occurrence
      else
        @series.current_occurrence
      end

    @history = @series.recurring_occurrences.closed.order(due_on: :desc).limit(12).includes(:allocations)
    @upcoming = @series.schedule.occurrences_between(Date.current + 1, Date.current + 400).first(3)

    # What each settled cycle actually cost. The frozen `expected_amount` is an
    # estimate, so reading it here would report averages of estimates beside the
    # per-year totals below, which are sums of real payments.
    paid_amounts = RecurringAllocation.confirmed
                                      .joins(:recurring_occurrence)
                                      .where(recurring_occurrences: {
                                               recurring_transaction_id: @series.id,
                                               status: "paid"
                                             })
                                      .group(:recurring_occurrence_id)
                                      .sum(:allocated_amount)
                                      .values
    @analytics = if paid_amounts.any?
      {
        average: Money.new(paid_amounts.sum / paid_amounts.size, @series.currency),
        lowest: Money.new(paid_amounts.min, @series.currency),
        highest: Money.new(paid_amounts.max, @series.currency),
        annualized: @series.monthly_equivalent_amount * 12,
        ytd: Money.new(ytd_paid_total, @series.currency)
      }
    end

    if params[:display] == "pane"
      # The expansion renders into whichever row frame asked for it; the id
      # is reflected back sanitized. close returns the empty frame, which
      # collapses the row.
      @pane_frame_id = params[:frame].to_s.gsub(/[^a-zA-Z0-9_-]/, "").presence || "bill_detail"
      if params[:close].present?
        render :pane_close, layout: false
        return
      end
    end

    load_summary_extras

    if params[:display] == "pane"
      # A pending suggestion is the one thing that changes what the expansion
      # should offer, so it is worth the one query.
      @pane_suggestion = @current_occurrence && RecurringAllocation.suggested
        .where(recurring_occurrence_id: @current_occurrence.id).first
      render :pane, layout: false
      return
    end

    # Only the bill's own page carries the deep material, so only it pays for
    # the aggregates behind it.
    load_deep_extras
    render
  end

  private
    # The plan plus the income facts the page states alongside it. One planner
    # instance answers both, so the income list and the periods always agree.
    def load_paycheck_plan
      planner = RecurringTransaction::PaycheckPlanner.new(Current.family, user: Current.user)
      # An empty plan (no periods to spread anything across) renders as no plan.
      @plan = planner.plan.presence
      @plan_unconvertible = planner.unconvertible_count

      @income_series = Current.family.recurring_transactions
                              .accessible_by(Current.user)
                              .where(bill_type: :income)
                              .where.not(status: %i[suggested ended])
                              .order(:name)
                              .to_a
      @next_income_by_series = planner.next_income_by_series

      # The next income EVENT, which is not the same fact as any one series'
      # next payday: two sources can land on the same day.
      arrivals = @next_income_by_series.values
      first_arrival = arrivals.min_by(&:due_on)
      if first_arrival
        same_day = arrivals.select { |occurrence| occurrence.due_on == first_arrival.due_on }
        total, unconvertible = total_of(same_day) { |occurrence| occurrence.resolved_expected_amount_money }
        @next_income = { date: first_arrival.due_on, occurrences: same_day, total: total, unconvertible: unconvertible }
      end

      @income_needs_attention = @income_series.any? { |series| !paycheck_income_plans?(series) }
    end

    # Only active, manually declared income defines paydays.
    def paycheck_income_plans?(series)
      series.active? && series.manual?
    end
    helper_method :paycheck_income_plans?

    # What the expansion needs: the handful of payments that actually settled
    # this bill lately. Cheap enough to run on every row someone opens.
    def load_summary_extras
      @recent_allocations = confirmed_allocations.includes(:entry).order(paid_on: :desc, created_at: :desc).limit(6)
    end

    # The bill's financial story: a year of payments by month, per-year totals,
    # and where the money last came from. Three grouped aggregates, which is
    # why they no longer run every time a row is expanded.
    def load_deep_extras
      confirmed = confirmed_allocations

      window_start = 11.months.ago.beginning_of_month.to_date
      by_month = confirmed
        .where("recurring_occurrences.due_on >= ?", window_start)
        .group(Arel.sql("date_trunc('month', recurring_occurrences.due_on)"))
        .sum(:allocated_amount)
        .transform_keys(&:to_date)

      @payment_history = (0..11).map do |offset|
        month = (window_start + offset.months)
        [ month, by_month.fetch(month, 0) ]
      end

      totals = confirmed.group(Arel.sql("date_trunc('year', recurring_occurrences.due_on)")).sum(:allocated_amount)
      counts = confirmed.group(Arel.sql("date_trunc('year', recurring_occurrences.due_on)")).count
      @yearly_metrics = totals.map do |year, total|
        count = counts.fetch(year, 1)
        { year: year.to_date.year, total: Money.new(total, @series.currency), average: Money.new(total / count, @series.currency) }
      end.sort_by { |row| -row[:year] }.first(4)

      last_allocation = confirmed.where.not(entry_id: nil).includes(entry: :account).order(paid_on: :desc, created_at: :desc).first
      @last_account = last_allocation&.entry&.account
    end

    def confirmed_allocations
      RecurringAllocation.confirmed
        .joins(:recurring_occurrence)
        .where(recurring_occurrences: { recurring_transaction_id: @series.id })
    end

    # The management table: every series of every type and status, filterable
    # and sortable. This is the power-user surface; the overview stays a
    # worklist.
    def load_all_series
      scope = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .includes(:merchant)

      if (search = params.dig(:q, :search)).present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
        scope = scope.left_joins(:merchant)
                     .where("recurring_transactions.name ILIKE :p OR merchants.name ILIKE :p", p: pattern)
      end

      # "Status" used to mean the SERIES lifecycle -- suggested, active, paused,
      # inactive, ended -- so there was no way to ask the question people
      # actually ask here, which is what is late and what is still owed. The
      # filter now speaks payment state, with the lifecycle values that still
      # matter (paused, ended) kept alongside.
      status = params.dig(:q, :status)

      if status.presence_in(LIFECYCLE_FILTERS)
        scope = scope.where(status: LIFECYCLE_STATUSES.fetch(status))
      end

      if (bill_type = params.dig(:q, :bill_type)).presence_in(RecurringTransaction.bill_types.keys)
        scope = scope.where(bill_type: bill_type)
      end

      scope = scope.includes(:recurring_occurrences) if status.presence_in(PAYMENT_FILTERS)

      @all_series = case params.dig(:q, :sort)
      when "name" then scope.order(:name, :amount)
      when "amount" then scope.order(amount: :desc)
      else scope.order(status: :asc, next_expected_date: :asc)
      end

      @all_series = filter_by_payment_state(@all_series, status) if status.presence_in(PAYMENT_FILTERS)

      load_subscription_rollup if bill_type == "subscription"
    end

    # Payment state lives on the occurrence and is derived from dates and
    # allocation sums, so it cannot be a WHERE clause. Occurrences are preloaded
    # above, and this table is a management surface for a few hundred bills.
    def filter_by_payment_state(series_list, status)
      series_list.to_a.select do |series|
        occurrence = series.current_occurrence
        next false if occurrence.nil?

        case status
        when "overdue" then occurrence.overdue?
        when "due"     then occurrence.derived_state == :due
        when "partial" then occurrence.partially_paid?
        when "paid"    then occurrence.paid?
        else false
        end
      end
    end

    # What the Subscriptions tab existed to answer. It was a filter promoted to
    # navigation -- bill_type: subscription, which All bills already offered --
    # so the rollup now rides the filter instead of a destination of its own.
    def load_subscription_rollup
      subscriptions = @all_series.select { |series| series.bill_type == "subscription" }
      active = subscriptions.select(&:active?)
      monthly, unconvertible = total_of_series(active) { |series| series.monthly_equivalent_amount.abs }

      @subscription_rollup = {
        monthly: monthly,
        annual: monthly ? monthly * 12 : nil,
        active_count: active.size,
        unconvertible: unconvertible
      }

      @recent_price_changes = RecurringPriceChange
                                .joins(:recurring_transaction)
                                .merge(RecurringTransaction.accessible_by(Current.user))
                                .where(recurring_transactions: { family_id: Current.family.id })
                                .where("effective_on >= ?", 1.year.ago.to_date)
                                .includes(:recurring_transaction)
                                .order(effective_on: :desc)
                                .limit(10)
    end

    def total_of_series(series_list, &value_of)
      return [ nil, 0 ] if series_list.empty?

      target = Current.family.currency
      unconvertible = 0

      total = series_list.reduce(Money.new(0, target)) do |sum, series|
        begin
          sum + value_of.call(series).exchange_to(target)
        rescue Money::ConversionError
          unconvertible += 1
          sum
        end
      end

      [ total, unconvertible ]
    end

    # Months are materialized on demand up to 13 months out (idempotent
    # upserts, so navigation is free to re-visit); navigation caps there,
    # which keeps every rendered chip a real, clickable occurrence.
    CALENDAR_FORWARD_LIMIT_MONTHS = 13

    def load_calendar
      today = Date.current
      @month = begin
        Date.strptime(params[:month].to_s, "%Y-%m").beginning_of_month
      rescue ArgumentError
        today.beginning_of_month
      end

      limit = (today + CALENDAR_FORWARD_LIMIT_MONTHS.months).beginning_of_month
      @month = limit if @month > limit
      @at_forward_limit = @month >= limit

      @grid_start = @month.beginning_of_week(:sunday)
      @grid_end = @month.end_of_month.end_of_week(:sunday)

      materialize_for_calendar(@grid_end) if @grid_end > today + 89

      occurrences = Current.family.recurring_occurrences
                           .where(recurring_transaction_id: payable_series_ids)
                           .due_between(@grid_start, @grid_end)
                           .includes(recurring_transaction: :merchant)
                           .to_a
      preload_allocation_sums(occurrences)

      @by_day = occurrences.group_by(&:due_on)
      month_occurrences = occurrences.select { |occurrence| occurrence.due_on.between?(@month, @month.end_of_month) }
      @month_expected, @month_unconvertible = total_of(month_occurrences) { |occurrence| occurrence.resolved_expected_amount_money }
      @month_paid, _ = total_of(month_occurrences) { |occurrence| occurrence.confirmed_allocated_money }
    end

    def materialize_for_calendar(through)
      Current.family.recurring_transactions
             .active
             .where(id: payable_series_ids)
             .find_each do |series|
        RecurringTransaction::OccurrenceGenerator.new(series).generate!(through: through)
      end
    end

    def ytd_paid_total
      RecurringAllocation.confirmed
                         .joins(:recurring_occurrence)
                         .where(recurring_occurrences: { recurring_transaction_id: @series.id })
                         .where("recurring_allocations.paid_on >= ?", Date.current.beginning_of_year)
                         .sum(:allocated_amount)
    end

    # Open occurrences through the horizon plus everything closed this
    # month, for every payable series (bills, subscriptions, and debt
    # payments alike). Inactive series ride along so their leftover open
    # occurrences can render as Dormant instead of haunting Past Due.
    def payable_series_ids
      debt_accounts = Account.where(accountable_type: %w[CreditCard Loan]).select(:id)

      Current.family.recurring_transactions
             .where(status: %w[active inactive])
             .where("amount > 0")
             .merge(
               RecurringTransaction.where(destination_account_id: nil)
                                   .or(RecurringTransaction.where(destination_account_id: debt_accounts))
             )
             .accessible_by(Current.user)
             .select(:id)
    end

    def payable_occurrences
      # Price changes ride along because bills_attention_reason asks every
      # row whether its amount changed recently.
      Current.family.recurring_occurrences
             .where(recurring_transaction_id: payable_series_ids)
             .where("due_on >= ? OR status = 'scheduled'", Date.current.beginning_of_month)
             .where("due_on <= ?", Date.current + 90)
             .includes(recurring_transaction: [ :merchant, :recurring_price_changes ])
             .to_a
    end

    def preload_allocation_sums(occurrences)
      sums = RecurringAllocation.confirmed
                                .where(recurring_occurrence_id: occurrences.map(&:id))
                                .group(:recurring_occurrence_id)
                                .sum(:allocated_amount)

      occurrences.each do |occurrence|
        occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0)
      end
    end

    # The month is the right container for planning and the wrong unit for
    # anyone whose income does not arrive monthly. Paid weekly, "this month"
    # collapses four paychecks and four rent payments into one list.
    #
    # These are markers inside the month, not a regrouping of it. Only returned
    # when income actually subdivides the month: monthly income yields a single
    # overlapping period and undeclared income yields none, and in both cases
    # the list renders exactly as it did before.
    def month_pay_periods(today, month_end)
      periods = RecurringTransaction::PaycheckPlanner
                  .new(Current.family, user: Current.user)
                  .plan(periods_limit: PAY_PERIOD_LIMIT)
      return [] if periods.blank?

      overlapping = periods.select do |period|
        period.starts_on <= month_end && period.ends_on >= today
      end

      overlapping.size > 1 ? overlapping : []
    end

    def compute_kpis(today, month_end)
      owed_now = @overdue + @this_month

      @remaining_this_month, @unconvertible_count = total_of(owed_now) { |occurrence| occurrence.remaining_amount_money }
      @paid_this_month_total, _ = total_of(@paid_this_month) { |occurrence| occurrence.confirmed_allocated_money }
      @due_next_seven, _ = total_of(owed_now.select { |occurrence| occurrence.effective_due_on <= today + 7 }) { |occurrence| occurrence.remaining_amount_money }
      @past_due_total, _ = total_of(@overdue) { |occurrence| occurrence.remaining_amount_money }
      @owed_count = owed_now.size
      @needs_action_count = owed_now.count { |occurrence| !occurrence.recurring_transaction.autopay? }
    end

    # A trial converting tomorrow and a month-old one-dollar price rise are not
    # the same news. Notices used to sort by date ascending, which put the
    # oldest and smallest first and buried the one thing you could still act on.
    TRIAL_URGENT_DAYS = 3
    MATERIAL_PRICE_SHIFT = 0.10

    Notice = Data.define(:kind, :series, :date, :detail) do
      def urgent?
        case kind
        when :trial then date <= Date.current + TRIAL_URGENT_DAYS
        when :price then price_shift >= MATERIAL_PRICE_SHIFT
        else false
        end
      end

      # How far a price moved, as a fraction of what it was. A dollar on a
      # ten-dollar subscription is worth saying; a dollar on the rent is not.
      def price_shift
        return 0 unless kind == :price && detail&.previous_amount.to_d.positive?

        ((detail.new_amount - detail.previous_amount).abs / detail.previous_amount).to_f
      end

      def price_percent
        return 0 unless kind == :price && detail&.previous_amount.to_d.positive?

        ((detail.new_amount - detail.previous_amount) / detail.previous_amount * 100).round
      end

      # Nearness to today in either direction: a change three days ago and a
      # renewal in three days are both current news.
      def distance
        (date - Date.current).to_i.abs
      end
    end

    # Lightweight, page-native reminders: the Insights pipeline is
    # preview-gated, so anything that must reach EVERY user renders here.
    def collect_notices
      today = Date.current
      window = today..(today + 14)
      series_scope = Current.family.recurring_transactions.accessible_by(Current.user).active

      notices = []
      series_scope.where(trial_ends_on: window).find_each do |series|
        notices << Notice.new(kind: :trial, series: series, date: series.trial_ends_on, detail: nil)
      end
      series_scope.where(renews_on: window).find_each do |series|
        notices << Notice.new(kind: :renewal, series: series, date: series.renews_on, detail: nil)
      end
      RecurringPriceChange.joins(:recurring_transaction)
                          .merge(RecurringTransaction.accessible_by(Current.user))
                          .where(recurring_transactions: { family_id: Current.family.id })
                          .where("effective_on >= ?", today - 30)
                          .includes(:recurring_transaction)
                          .find_each do |change|
        notices << Notice.new(kind: :price, series: change.recurring_transaction, date: change.effective_on, detail: change)
      end

      notices.sort_by { |notice| [ notice.urgent? ? 0 : 1, notice.distance ] }
    end

    # Detection has been creating recurring rows from bank data since long
    # before this page existed, so a family arriving here for the first time
    # meets bills nobody ever confirmed. Counts them, and returns zero the
    # moment there is any sign the user has worked with Bills at all -- a
    # declared bill, a dismissed suggestion, or a payment they recorded
    # themselves -- so the prompt clears itself and needs no stored state.
    def detected_awaiting_review
      series = Current.family.recurring_transactions.accessible_by(Current.user)
      return 0 if series.where(manual: true).exists?
      return 0 if series.where(status: :ended).exists?

      user_touched = RecurringAllocation.where.not(source: :auto_matched)
                                        .joins(:recurring_occurrence)
                                        .where(recurring_occurrences: { family_id: Current.family.id })
      return 0 if user_touched.exists?

      series.where(manual: false, status: :active).count
    end

    def accessible_suggested_series
      Current.family.recurring_transactions
             .accessible_by(Current.user)
             .suggested
    end

    # Family-wide, not user-scoped: occurrence materialization is the same
    # machinery the sync job runs, and a partial per-user generation would
    # leave the family half-materialized forever.
    def materialize_missing_occurrences
      Current.family.recurring_transactions.active.find_each do |series|
        RecurringTransaction::OccurrenceGenerator.new(series).generate!
      end
    end

    def suggested_allocations
      RecurringAllocation
        .suggested
        .joins(recurring_occurrence: :recurring_transaction)
        .where(recurring_occurrences: { family_id: Current.family.id })
        .merge(RecurringTransaction.accessible_by(Current.user))
        # Income never reviews here: the matcher no longer suggests it, and
        # this filter also retires any suggestion written before that rule.
        .merge(RecurringTransaction.where.not(bill_type: "income"))
        .includes(:entry, recurring_occurrence: { recurring_transaction: :merchant })
        # The confidence the matcher scored these with was sitting unused on
        # the row while the queue ordered itself by when the job happened to
        # run. Most-certain question first.
        .order(match_confidence: :desc, created_at: :asc)
    end

    # Converted into the family currency because the headline answers "how
    # much do I owe", which is one number. A pair with no rate is left out
    # and counted rather than silently understating the total. Returns
    # [total, unconvertible_count] so each caller keeps its own count.
    def total_of(occurrences, &value_of)
      return [ nil, 0 ] if occurrences.empty?

      target = Current.family.currency
      unconvertible = 0

      total = occurrences.reduce(Money.new(0, target)) do |sum, occurrence|
        begin
          sum + value_of.call(occurrence).exchange_to(target)
        rescue Money::ConversionError
          unconvertible += 1
          sum
        end
      end

      [ total, unconvertible ]
    end
end
