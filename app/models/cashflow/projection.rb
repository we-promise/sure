# Projects a family's cash balance forward, one day at a time, INCLUDING income.
#
# Sure's only existing forward look, Insight::Generators::CashFlowWarningGenerator,
# subtracts a median spend baseline and the recurring bills and adds nothing
# back, so its balance can only fall. A salary landing on the 28th appears
# nowhere in its 30 days, which turns an ordinary month into an alarming
# headline figure the user cannot act on. That generator is left untouched; this
# is a separate engine callers can opt into.
#
# Deterministic on purpose: the numbers are computed here so a model interprets
# them rather than doing the arithmetic itself.
class Cashflow::Projection
  DEFAULT_HORIZON_DAYS = 90
  MAX_HORIZON_DAYS = 365

  # A discrete, dated movement. Distinguished from the smeared discretionary
  # baseline, which has no date of its own.
  Event = Data.define(:date, :label, :amount, :direction, :source)

  Day = Data.define(:date, :inflows, :outflows, :discretionary, :fees, :closing_balance)

  Breach = Data.define(:label, :threshold, :first_date, :deepest_date, :deepest_balance, :days_below)

  LowPoint = Data.define(:date, :balance)

  attr_reader :family, :user, :horizon_days

  def initialize(family, user:, horizon_days: DEFAULT_HORIZON_DAYS, account_ids: nil, extra_thresholds: [], adjustments: [])
    @family = family
    @user = user
    @horizon_days = horizon_days.to_i.clamp(1, MAX_HORIZON_DAYS)
    @account_ids = account_ids
    # Scenario deltas, injected by the simulator as extra Events so a scenario
    # is the base projection plus movements rather than a second engine.
    @adjustments = adjustments
    @extra_thresholds = extra_thresholds
  end

  def start_date = Date.current
  def end_date = Date.current + horizon_days

  # Memos that cannot depend on the adjustments, so a sibling projection can
  # inherit them. An allowlist rather than an exclusion list on purpose: adding
  # a memo here is a decision, forgetting to exclude one would be a silent bug.
  # `@events`, `@days` and everything derived from them are deliberately absent.
  SHAREABLE_MEMOS = %i[
    @accounts @starting_balance @income_statement
    @accessible_series @active_series @declared_income_series
    @occurrences_in_window @series_frontier
    @recurring_events @unschedulable_series @daily_discretionary_spend
  ].freeze

  # Same base, different dated movements. simulate_scenarios built one full
  # projection per scenario plus a baseline, so a single call re-ran the account
  # scope, the series scope, the occurrence window, the frontier and the income
  # statement six times over for inputs that are identical by construction.
  def with_adjustments(adjustments)
    sibling = self.class.new(
      family,
      user: user,
      horizon_days: horizon_days,
      account_ids: @account_ids,
      extra_thresholds: @extra_thresholds,
      adjustments: adjustments
    )

    SHAREABLE_MEMOS.each do |memo|
      next unless instance_variable_defined?(memo)

      sibling.instance_variable_set(memo, instance_variable_get(memo))
    end

    sibling
  end

  def accounts
    @accounts ||= begin
      scope = user.accessible_accounts.visible
                  .where(accountable_type: "Depository")
                  .where(currency: family.currency)
      scope = scope.where(id: @account_ids) if @account_ids.present?
      scope.includes(:accountable).to_a
    end
  end

  def starting_balance
    @starting_balance ||= accounts.sum { |account| account.balance.to_d }
  end

  def events
    @events ||= (recurring_events + @adjustments).sort_by { |event| [ event.date, event.label ] }
  end

  # Everything not covered by a known recurring series, smeared evenly. Derived
  # from the median month rather than the mean so one exceptional month does not
  # set the baseline, and floored at zero so a family whose recurring bills
  # already exceed its median spend is not credited with phantom income.
  def daily_discretionary_spend
    @daily_discretionary_spend ||= begin
      median_monthly = income_statement.median_expense(interval: "month").to_d
      monthly_recurring = monthly_recurring_outflow

      [ median_monthly - monthly_recurring, 0.to_d ].max / 30.4375
    end
  end

  def days
    @days ||= build_days
  end

  def low_point
    @low_point ||= begin
      lowest = days.min_by(&:closing_balance)
      LowPoint.new(date: lowest.date, balance: lowest.closing_balance)
    end
  end

  # One entry per threshold actually crossed. A threshold never reached is
  # absent rather than reported as a zero-day breach, so the presence of a key
  # is itself the signal.
  def breaches
    @breaches ||= thresholds.filter_map do |label, value|
      below = days.select { |day| day.closing_balance < value }
      next if below.empty?

      deepest = below.min_by(&:closing_balance)

      Breach.new(
        label: label,
        threshold: value,
        first_date: below.first.date,
        deepest_date: deepest.date,
        deepest_balance: deepest.closing_balance,
        days_below: below.size
      )
    end
  end

  # The floor each account may fall to, from the overdraft terms, plus zero.
  # Without an arranged overdraft the floor IS zero and the two coincide, which
  # is why they are labelled rather than returned as bare numbers.
  def thresholds
    @thresholds ||= begin
      list = { "zero" => 0.to_d }

      floor = overdraft_floor
      list["overdraft_limit"] = floor if floor.negative?

      @extra_thresholds.each_with_index do |value, index|
        list["custom_#{index + 1}"] = value.to_d
      end

      list
    end
  end

  # Aggregate floor across the projected accounts. Summing is right because the
  # projection itself runs on the pooled balance: a family with two accounts,
  # each with a 400 facility, really can reach -800 in total.
  def overdraft_floor
    accounts.sum do |account|
      depository = account.accountable
      depository.is_a?(Depository) ? depository.overdraft_floor.to_d : 0.to_d
    end
  end

  def declared_income?
    declared_income_series.any?
  end

  # Whether the projection actually carries incoming money, whatever its
  # provenance. `declared_income?` is narrower on purpose (hand-declared series
  # only), but the two must never be confused: the events are built from every
  # active series, so a detected-then-confirmed salary IS counted, and saying
  # "this projection contains no income" over the top of it would be false.
  def income_counted?
    recurring_events.any? { |event| event.direction == :in }
  end

  # Series whose schedule could not be resolved, so their bills are missing from
  # the projection. Named rather than dropped: the low point is too high by
  # whatever these would have cost.
  def unschedulable_series
    recurring_events
    @unschedulable_series || []
  end

  # Stated rather than implied. Every figure here rests on these, and an
  # assistant that presents a projection without them is overstating how much
  # is actually known.
  def assumptions
    {
      accounts_included: accounts.map(&:name),
      accounts_excluded_note: excluded_accounts_note,
      starting_balance: starting_balance,
      daily_discretionary_spend: daily_discretionary_spend.round(2),
      discretionary_basis: "median monthly expense minus known recurring outflows, spread evenly",
      declared_income: declared_income?,
      income_counted: income_counted?,
      series_not_scheduled: unschedulable_series.presence,
      recurring_events_counted: recurring_events.size,
      occurrences_materialized_through: materialization_frontier
    }.compact
  end

  def warnings
    list = []

    if accounts.empty?
      list << "No depository account in #{family.currency} is visible to this user, so there is nothing to project."
    end

    if !income_counted?
      list << "No income has been declared (Bills, Income plan) and no recurring inflow was found, so this " \
              "projection contains NO incoming salary or other earnings. Say this plainly before quoting any " \
              "low point: the figure is a floor, not a forecast."
    elsif !declared_income?
      list << "The income in this projection comes from detected recurring inflows, not from a declared " \
              "income plan (Bills, Income plan). Detection can miss a pay rise, a bonus or a changed pay " \
              "date, so treat the low point as indicative and say the income was inferred, not declared."
    end

    if unschedulable_series.any?
      list << "#{unschedulable_series.size} recurring series could not be scheduled " \
              "(#{unschedulable_series.take(3).join(', ')}), most often a non-monthly series saved without " \
              "an anchor date. Their bills are MISSING from this projection, so the low point is too high " \
              "by whatever they cost."
    end

    if overdraft_floor.zero?
      list << "No arranged overdraft is recorded on these accounts, so the projection treats zero as the floor. " \
              "If the user has a facility, recording it changes which crossings matter."
    end

    if fee_bearing_accounts.size > 1
      list << "#{fee_bearing_accounts.size} accounts carry different intervention fee terms. The projection " \
              "runs on a pooled balance and cannot attribute a payment to one of them, so it applies the " \
              "first account's terms only. Treat the simulated fees as indicative."
    end

    list
  end

  private
    def income_statement
      @income_statement ||= IncomeStatement.new(family, user: user, accounts: accounts)
    end

    def build_days
      balance = starting_balance
      events_by_date = events.group_by(&:date)
      fees_this_month = Hash.new { |hash, key| hash[key] = [] }

      (start_date..end_date).map do |date|
        day_events = events_by_date.fetch(date, [])
        inflows = day_events.select { |event| event.direction == :in }.sum(&:amount)
        outflows = day_events.select { |event| event.direction == :out }.sum(&:amount)

        balance += inflows
        balance -= outflows
        balance -= daily_discretionary_spend

        fees = intervention_fees(date, day_events, balance, fees_this_month)
        balance -= fees

        Day.new(
          date: date,
          inflows: inflows.round(2),
          outflows: outflows.round(2),
          discretionary: daily_discretionary_spend.round(2),
          fees: fees.round(2),
          closing_balance: balance.round(2)
        )
      end
    end

    # The bank charges per payment presented while the account sits past its
    # limit, so the fee is driven by the discrete events of the day, never by
    # the smeared baseline, which is not a payment and cannot trigger anything.
    #
    # The whole month is re-capped on every charging day and only the increment
    # is taken, which is what makes a cap that binds mid-month stop the charges
    # for the rest of it.
    def intervention_fees(date, day_events, balance, fees_this_month)
      terms = fee_terms
      return 0.to_d if terms.nil?
      return 0.to_d unless balance < overdraft_floor

      month_key = date.strftime("%Y-%m")

      day_events.select { |event| event.direction == :out }.each do |event|
        fee = terms.intervention_fee_for(event.amount)
        fees_this_month[month_key] << fee if fee&.positive?
      end

      charged_so_far = charged_fees[month_key] || 0.to_d
      capped = terms.capped_monthly_fees(fees_this_month[month_key])
      charged_fees[month_key] = capped

      [ capped - charged_so_far, 0.to_d ].max
    end

    def charged_fees
      @charged_fees ||= {}
    end

    # One set of terms, not a sum over accounts. The projection runs on a pooled
    # balance, so a payment cannot be attributed to a particular account, and
    # applying every account's fee schedule to the same payment would charge it
    # once per account. When several accounts disagree the first is used and
    # `warnings` says so.
    def fee_terms
      return @fee_terms if defined?(@fee_terms)

      @fee_terms = fee_bearing_accounts.first
    end

    def fee_bearing_accounts
      @fee_bearing_accounts ||= accounts.map(&:accountable)
                                        .grep(Depository)
                                        .select { |depository| depository.intervention_fee_amount.present? }
    end

    def recurring_events
      @recurring_events ||= open_occurrence_events + projected_schedule_events
    end

    # Materialized occurrences are authoritative wherever they exist: they carry
    # partial payments, snoozes and skips that a schedule cannot know about.
    def open_occurrence_events
      occurrences_in_window.select { |occurrence| occurrence.status == "scheduled" }.map do |occurrence|
        series = occurrence.recurring_transaction

        Event.new(
          date: occurrence.effective_due_on,
          label: series.name.presence || series.merchant&.name || "Recurring",
          amount: occurrence.remaining_amount.to_d,
          direction: series.amount.to_d.negative? ? :in : :out,
          source: "occurrence"
        )
      end
    end

    # Occurrences are only generated 90 days out
    # (RecurringTransaction::OccurrenceGenerator::HORIZON_DAYS), so a longer
    # horizon would silently lose every bill beyond that frontier and read as
    # unrealistically comfortable. Past each series' own last materialized row,
    # the schedule takes over. Splitting per series and per date is what keeps
    # the two sources from double counting.
    def projected_schedule_events
      @unschedulable_series = []

      active_series.flat_map do |series|
        frontier = series_frontier[series.id]
        from = frontier ? [ frontier + 1, start_date ].max : start_date
        next [] if from > end_date

        dates = schedule_dates(series, from)
        next [] if dates.nil?

        dates.map do |date|
          Event.new(
            date: date,
            label: series_label(series),
            amount: series.amount.to_d.abs,
            direction: series.amount.to_d.negative? ? :in : :out,
            source: "schedule"
          )
        end
      end
    end

    # Scoped to the one series that cannot be scheduled. A rescue around the
    # whole loop would drop every OTHER series' events with it and turn the
    # projection into a comfortable-looking fiction, which is the exact failure
    # this class exists to prevent. What is dropped is counted and surfaced in
    # `warnings`, never swallowed.
    def schedule_dates(series, from)
      series.schedule.occurrences_between(from, end_date)
    rescue ArgumentError
      @unschedulable_series << series_label(series)
      nil
    end

    def series_label(series)
      series.name.presence || series.merchant&.name || "Recurring"
    end

    # Every recurring read goes through this one scope. #accounts is restricted
    # to the caller, but the series driving the projection were read off the
    # family, and their names and amounts are echoed back verbatim in `events`,
    # `assumptions` and `warnings`. With per-account sharing turned off that let
    # a member read another member's private bills and salary out of a
    # projection built on their own accounts. Same scope get_recurring_transactions
    # and the Bills tools use; its own comment exists for this exact reason.
    def accessible_series
      @accessible_series ||= family.recurring_transactions.accessible_by(user)
    end

    def active_series
      @active_series ||= accessible_series
                           .where(status: :active, destination_account_id: nil)
                           .where(currency: family.currency)
                           .includes(:merchant, :recurrence_rules)
                           .to_a
    end

    def declared_income_series
      @declared_income_series ||= active_series.select { |series| series.bill_type == "income" && series.manual? }
    end

    def occurrences_in_window
      @occurrences_in_window ||= family.recurring_occurrences
                                       .joins(:recurring_transaction)
                                       .where(recurring_transaction_id: accessible_series.select(:id))
                                       .where(recurring_transactions: { status: :active, destination_account_id: nil })
                                       .where(currency: family.currency)
                                       .where(due_on: start_date..end_date)
                                       .includes(recurring_transaction: :merchant)
                                       .to_a
    end

    # Latest materialized occurrence per series, closed rows included: the
    # frontier is about what the generator has written, not about what is still
    # owed.
    def series_frontier
      @series_frontier ||= family.recurring_occurrences
                                 .where(recurring_transaction_id: accessible_series.select(:id))
                                 .group(:recurring_transaction_id)
                                 .maximum(:due_on)
    end

    def materialization_frontier
      series_frontier.values.compact.max
    end

    # Each series amortized over its OWN cadence, never over the horizon. An
    # annual premium that happens to land inside a 90-day window is worth a
    # twelfth of itself per month, not a third: dividing the windowed total by
    # the horizon inflated the known recurring load, drove the discretionary
    # baseline to zero through the `max(…, 0)` below it, and handed back a
    # projection that spent nothing day to day. Same normalization as
    # RecurringTransaction#monthly_equivalent_amount, so the two agree.
    def monthly_recurring_outflow
      active_series.sum(0.to_d) do |series|
        series.amount.to_d.positive? ? monthly_equivalent(series) : 0.to_d
      end
    end

    def monthly_equivalent(series)
      per_year = series.schedule.occurrences_per_year.to_d
      series.amount.to_d.abs * per_year / 12
    rescue ArgumentError
      # Already named in `warnings` through unschedulable_series; counting it as
      # zero here keeps the discretionary baseline generous rather than hiding
      # the gap behind an invented cadence.
      0.to_d
    end

    # Scoped the same way as `accounts`. A caller who named the accounts it
    # cares about should not be told about others it deliberately left out.
    def excluded_accounts_note
      scope = user.accessible_accounts.visible
                  .where(accountable_type: "Depository")
                  .where.not(currency: family.currency)
      scope = scope.where(id: @account_ids) if @account_ids.present?
      excluded = scope.count

      return nil if excluded.zero?

      "#{excluded} depository account(s) in another currency are not included; converting them would " \
      "need a rate per future day, which this projection does not invent."
    end
end
