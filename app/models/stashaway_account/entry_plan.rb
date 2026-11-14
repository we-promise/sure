# The entries one Sure account should hold for the StashAway portfolios
# grouped into it, built from their stored transactions and daily values:
#
# - money moving in or out ("Deposit" / "Withdrawal"), except moves between
#   two portfolios of the same account: a withdrawal StashAway describes as
#   a transfer, or whose operation id a deposit of another portfolio shares,
#   with the matching deposit,
# - dividends, rebates and management fees as rows of their own,
# - one "Returns (month-end adjustment, YYYY-MM)" row per month that brings
#   the running balance to StashAway's portfolio value (NAV) at every month
#   end. The current month's row is a month-to-date one dated on the latest
#   NAV day, which later syncs move and resize under the same external id.
#
# A portfolio StashAway no longer serves detail for, closed or failing, is
# planned from the detail stored for it last. A closed one is worth nothing
# after its last valued day, and the value that left with it is booked as a
# withdrawal the day after.
#
# Rows the account keeps as they are (`protected`) count at their ledger
# figures, so the returns rows bring the balance to NAV around them.
#
# A plan that cannot be trusted is not applicable (`applicable` false, with
# the `reason`): the caller changes nothing and reports the reason.
#
# Amounts use Sure's sign convention: negative is money coming in. Row names
# are in the current locale; the processor builds the plan in the family's.
class StashawayAccount::EntryPlan
  PlannedEntry = Data.define(:external_id, :date, :amount, :name, :category, :kind, :activity_label, :goal_id, :transfer, :operation_id) do
    def initialize(transfer: false, operation_id: nil, **rest) = super(transfer: transfer, operation_id: operation_id, **rest)
  end

  # A StashAway row already in the ledger that a sync leaves as it is.
  ProtectedEntry = Data.define(:external_id, :date, :amount)

  Result = Data.define(:entries, :pending, :last_nav_date, :final_nav, :expected_balance, :history_start, :start, :base, :warnings,
                       :applicable, :reason)

  # Rows that stay inside the portfolio: buys, sells and currency conversions.
  IGNORED_TYPES = %w[Buy Sell FxConversion].freeze

  CATEGORY_INCOME = "Income".freeze
  CATEGORY_RETURNS = "Investment Returns".freeze
  CATEGORY_FEES = "Fees".freeze
  CATEGORY_NAMES = [ CATEGORY_INCOME, CATEGORY_RETURNS, CATEGORY_FEES ].freeze

  HALF_CENT = BigDecimal("0.005")

  # A step function over dated values: the value on or before a date, 0
  # before the first point. A series that `ends` is 0 after its last point
  # too (a closed portfolio); otherwise the last value carries forward.
  class Series
    attr_reader :first, :last

    def initialize(points, ends: false)
      @points = Array(points).filter_map do |point|
        date = StashawayAccount::EntryPlan.parse_date(point["date"])
        amount = StashawayAccount::EntryPlan.parse_amount(point["amount"])
        [ date, amount ] if date && amount
      end.sort_by(&:first)
      @dates = @points.map(&:first)
      @first = @dates.first
      @last = @dates.last
      @ends = ends
    end

    def empty?
      @points.empty?
    end

    def at(date)
      return BigDecimal("0") if @ends && @last && date > @last

      index = @dates.bsearch_index { |d| d > date }
      index = @points.size if index.nil?
      index.zero? ? BigDecimal("0") : @points[index - 1].last
    end
  end

  class << self
    # Half away from zero, as StashAway's figures are.
    def round2(value)
      value.to_d.round(2, BigDecimal::ROUND_HALF_UP)
    end

    def parse_date(value)
      Date.iso8601(value.to_s[0, 10])
    rescue Date::Error
      nil
    end

    def parse_amount(value)
      return nil if value.nil? || value.is_a?(TrueClass) || value.is_a?(FalseClass)

      amount = BigDecimal(value.to_s)
      amount.finite? ? amount : nil
    rescue ArgumentError
      nil
    end
  end

  # goals:     stored goal records (see StashawayItem::Importer#goal_record)
  # currency:  the Sure account's currency
  # start:     the first date to plan, or nil for the whole history
  # base:      the Sure account's balance on the day before `start`. The first
  #            month's return is measured from it, so the balance still ends
  #            on StashAway's value when earlier rows came from elsewhere.
  #            nil while that balance is not known, which makes the plan not
  #            applicable.
  # protected: ProtectedEntry rows of the account that a sync leaves as they
  #            are, whether the plan still has them or not
  def initialize(goals:, currency:, start: nil, base: 0, protected: [])
    @goals = Array(goals)
    @currency = currency
    @start = start
    @base = base&.to_d
    @protected = Array(protected)
    @warnings = []
  end

  def build
    entries = drop_internal_moves(flow_and_income_entries)
    entries = entries.select { |entry| entry.date >= start } if start

    if (reason = not_applicable_reason)
      warnings << I18n.t("stashaway_items.plan_warnings.nothing_applied", reason: reason)
      return Result.new(entries: [], pending: [], last_nav_date: nil, final_nav: nil, expected_balance: nil, history_start: nil,
                        start: start, base: base, warnings: warnings, applicable: false, reason: reason)
    end

    # Rows newer than the latest NAV day wait for a later sync, so the
    # balance always ends on a known value, as do a failed portfolio's rows
    # after its own last valued day.
    pending, entries = entries.partition { |entry| entry.date > last_nav_date || awaits_own_value?(entry) }
    entries = in_date_order(entries)

    Result.new(
      entries: in_date_order(entries + return_adjustments(entries)),
      pending: pending,
      last_nav_date: last_nav_date,
      final_nav: nav_at(last_nav_date),
      expected_balance: start && start > last_nav_date ? round2(base) : nav_at(last_nav_date),
      history_start: first_nav_date,
      start: start,
      base: base,
      warnings: warnings,
      applicable: true,
      reason: nil
    )
  end

  private

    attr_reader :goals, :currency, :start, :base, :protected, :warnings

    def round2(value)
      self.class.round2(value)
    end

    # Why the plan must not be applied, or nil. Without the balance to
    # measure the first month from, the pre-start history would be booked
    # as a return; without StashAway's value for a portfolio whose rows are
    # planned, the returns rows would cancel those rows and the anchor
    # would miss that portfolio. The same goes for one StashAway failed to
    # serve this time, with no value stored for it in the account currency:
    # left out, the account would be anchored without it and its rows
    # removed.
    def not_applicable_reason
      if start && base.nil?
        I18n.t("stashaway_items.plan_warnings.reasons.balance_unknown", date: I18n.l(start.prev_day))
      elsif navs.empty?
        I18n.t("stashaway_items.plan_warnings.reasons.no_value_history", currency: currency)
      else
        unvalued = goals.select do |goal|
          served_again?(goal) && Array(goal["transactions"]).any? && series_for(goal).nil?
        end
        # One StashAway lists but has failed to serve every time so far may
        # hold value too: without it, the account would be anchored on the
        # others alone.
        undetailed = goals.select do |goal|
          served_again?(goal) && goal["unavailable"].present? && Array(goal["transactions"]).empty? && series_for(goal).nil?
        end
        if unvalued.any?
          I18n.t("stashaway_items.plan_warnings.reasons.unvalued", names: unvalued.map { |goal| goal["name"] }.to_sentence, currency: currency)
        elsif undetailed.any?
          I18n.t("stashaway_items.plan_warnings.reasons.undetailed", names: undetailed.map { |goal| goal["name"] }.to_sentence)
        end
      end
    end

    def flow_and_income_entries
      unknown_types = Hash.new(0)

      entries = goals.flat_map do |goal|
        next [] unless detail_to_plan?(goal)

        rows = Array(goal["transactions"]).flat_map do |item|
          next [] unless completed?(item["groupedStatus"])

          Array(item["transactions"]).filter_map do |row|
            next unless completed?(row["transactionStatus"])

            type = row["transactionType"].presence || item["groupedType"]
            next if IGNORED_TYPES.include?(type)

            classification = classify(type, row["description"], row.dig("metadata", "securityCode"))
            if classification == :unknown
              unknown_types[type] += 1
              next
            end
            next if classification.nil?

            planned_entry(goal, item, row, classification)
          end
        end

        rows + closing_withdrawal(goal, rows)
      end

      unknown_types.each do |type, count|
        warnings << I18n.t("stashaway_items.plan_warnings.unknown_type", count: count, type: type)
      end

      entries
    end

    # Whether a portfolio has detail to plan from. StashAway serves none for
    # one it closed or failed on, so the detail stored for it last is used,
    # with a warning; one never stored, or never valued in the account
    # currency, has nothing to plan.
    def detail_to_plan?(goal)
      return true if goal["unavailable"].blank?

      why = I18n.t("stashaway_items.plan_warnings.unavailable.#{goal["unavailable"].to_s.parameterize(separator: "_")}", default: goal["unavailable"].to_s)
      if Array(goal["transactions"]).empty?
        warnings << I18n.t("stashaway_items.plan_warnings.no_detail", name: goal["name"], reason: why)
        false
      elsif series_for(goal).nil?
        warnings << I18n.t("stashaway_items.plan_warnings.no_detail_or_value_history", name: goal["name"], reason: why, currency: currency)
        false
      else
        warnings << I18n.t("stashaway_items.plan_warnings.stored_detail_used", name: goal["name"], reason: why)
        true
      end
    end

    def planned_entry(goal, item, row, classification)
      money = row["amount"].is_a?(Hash) ? row["amount"] : {}
      signed = self.class.parse_amount(money["amount"])
      return if signed.nil? || signed.zero?

      date = self.class.parse_date(item["groupedDate"].presence || row["date"])
      return unless date

      from = money["currency"].presence || currency
      value = signed
      name = classification[:name]

      if row["id"].blank?
        warnings << I18n.t("stashaway_items.plan_warnings.no_transaction_id", portfolio: goal["name"], date: I18n.l(date), name: name, amount: money_text(from, signed))
        return
      end

      if from != currency
        rate = fx_rate(goal, from, date)
        unless rate
          warnings << I18n.t("stashaway_items.plan_warnings.no_rate", portfolio: goal["name"], date: I18n.l(date), from: from, to: currency, name: name, amount: money_text(from, signed))
          return
        end

        rate = rate.round(4)
        value = signed * rate
        name = I18n.t("stashaway_items.entries.converted", name: name, amount: money_text(from, signed), rate: rate_text(rate))
      end

      PlannedEntry.new(
        external_id: "tx:#{row["id"]}",
        date: date,
        amount: -round2(value),
        name: name,
        category: classification[:category],
        kind: classification[:kind],
        activity_label: classification[:label],
        goal_id: goal["id"],
        transfer: classification[:kind] == :flow && row["description"].to_s.match?(/transfer/i),
        operation_id: row.dig("metadata", "operationId").presence
      )
    end

    # StashAway has no detail for a closed portfolio, so the money that left
    # between the last sync and the closing is booked on the first day it is
    # known to be gone, where the user can match it to the bank side. Values
    # lag the transactions by a day or two, so rows the stored detail already
    # holds after the last valued day count first: a withdrawal there took
    # that money already, and only what it left is booked.
    def closing_withdrawal(goal, rows)
      series = series_for(goal)
      return [] unless closed?(goal) && series

      after_last_value = rows.select { |row| row.date > series.last }
      amount = round2(series.at(series.last) - after_last_value.sum(&:amount))
      return [] if amount < HALF_CENT

      [ PlannedEntry.new(
        external_id: "tx:closed:#{goal["id"]}",
        date: series.last.next_day,
        amount: amount,
        name: I18n.t("stashaway_items.entries.portfolio_closed"),
        category: nil,
        kind: :flow,
        activity_label: "Withdrawal",
        goal_id: goal["id"]
      ) ]
    end

    def completed?(status)
      status.blank? || status.to_s.casecmp?("completed")
    end

    def closed?(goal)
      goal["state"] == "CLOSED"
    end

    # A row of a portfolio StashAway failed to serve this time, dated after
    # the last day its stored detail is valued on: the value carried forward
    # for it does not hold the row yet, so booked now, the month's return
    # would cancel it. It waits for a sync that values the portfolio past
    # it. A closed or unlisted portfolio is never valued again, so its rows
    # do not wait (a closed one's closing withdrawal accounts for them).
    def awaits_own_value?(entry)
      goal = entry.goal_id && goals.find { |candidate| candidate["id"] == entry.goal_id }
      return false unless goal && goal["unavailable"].present? && served_again?(goal)

      series = series_for(goal)
      series.present? && entry.date > series.last
    end

    def open_and_available?(goal)
      goal["unavailable"].blank? && !closed?(goal)
    end

    # Whether StashAway serves the portfolio's detail on a later sync: an
    # open one it still lists, even when it failed to serve it this time. A
    # closed one, or one it no longer lists, never comes back, so waiting
    # for its value would stop the account for good; it is left out instead.
    def served_again?(goal)
      !closed?(goal) && goal["unavailable"] != "unlisted"
    end

    # nil for rows that are not income or flows (or not final yet), :unknown
    # for types this does not know, which are left to the month-end
    # adjustment. Flows carry the investment activity label Reports count.
    def classify(type, description, security_code)
      description = description.to_s

      case type
      when "Deposit"
        { kind: :flow, name: I18n.t("stashaway_items.entries.deposit"), category: nil, label: "Contribution" }
      when "Withdrawal"
        { kind: :flow, name: I18n.t("stashaway_items.entries.withdrawal"), category: nil, label: "Withdrawal" }
      when "Entitlement"
        return nil if description.match?(/receivable/i)

        name = security_code.present? ? I18n.t("stashaway_items.entries.dividend_received_for", code: security_code) : I18n.t("stashaway_items.entries.dividend_received")
        { kind: :income, name: name, category: CATEGORY_INCOME }
      when "DividendRebate"
        return nil if description.match?(/receivable/i)

        { kind: :income, name: I18n.t("stashaway_items.entries.dividend_rebate"), category: CATEGORY_RETURNS }
      when "DividendTaxReimbursement"
        { kind: :income, name: I18n.t("stashaway_items.entries.dividend_tax_reimbursement"), category: CATEGORY_INCOME }
      when "CashRebate"
        { kind: :income, name: I18n.t("stashaway_items.entries.cash_rebate"), category: CATEGORY_INCOME }
      when "Fee"
        { kind: :fee, name: fee_name(description), category: CATEGORY_FEES }
      else
        :unknown
      end
    end

    # StashAway describes a management fee by the month it covers, "YYYY-MM".
    def fee_name(description)
      match = /\A(\d{4})-(\d{2})\z/.match(description.strip)
      unless match && Date.valid_date?(match[1].to_i, match[2].to_i, 1)
        return I18n.t("stashaway_items.entries.management_fee")
      end

      month = Date.new(match[1].to_i, match[2].to_i, 1)
      I18n.t("stashaway_items.entries.management_fee_for", month: I18n.l(month, format: "%b %Y"))
    end

    # An amount and a rate in the current locale's number format.
    def money_text(currency, amount)
      "#{currency} #{ActiveSupport::NumberHelper.number_to_rounded(amount, precision: 2, locale: I18n.locale)}"
    end

    def rate_text(rate)
      ActiveSupport::NumberHelper.number_to_rounded(rate, precision: 4, strip_insignificant_zeros: true, locale: I18n.locale)
    end

    # The rate from `from` into the account currency on a date, implied by
    # the goal's own value reported in both currencies. Falls back to the
    # nearest earlier day, then the earliest one.
    def fx_rate(goal, from, date)
      target = nav_points(goal, currency)
      source = nav_points(goal, from)
      return nil if target.empty? || source.empty?

      source_by_date = source.each_with_object({}) do |point, by_date|
        point_date = self.class.parse_date(point["date"])
        by_date[point_date] = self.class.parse_amount(point["amount"]) if point_date
      end

      rates = target.filter_map do |point|
        point_date = self.class.parse_date(point["date"])
        amount = self.class.parse_amount(point["amount"])
        divisor = source_by_date[point_date]
        next unless point_date && amount && divisor && !divisor.zero?

        rate = amount / divisor
        [ point_date, rate ] if rate.positive?
      end.sort_by(&:first)
      return nil if rates.empty?

      (rates.select { |rate_date, _| rate_date <= date }.last || rates.first).last
    end

    def nav_points(goal, nav_currency)
      Array(goal.dig("performance", nav_currency, "nav"))
    end

    # Moves between two portfolios that both feed this account stay inside it.
    # A withdrawal is a move when StashAway describes it as a transfer, or
    # when a deposit of another portfolio on the same day, for the same
    # amount, shares its operation id; that deposit is taken first. A pair
    # with neither mark is a coincidence and stays.
    def drop_internal_moves(entries)
      flows = entries.select { |entry| entry.kind == :flow }
      dropped = Set.new

      flows.each do |outflow|
        next if outflow.amount <= 0 || dropped.include?(outflow.external_id)

        candidates = flows.select do |candidate|
          !dropped.include?(candidate.external_id) && candidate.amount == -outflow.amount &&
            candidate.date == outflow.date && candidate.goal_id != outflow.goal_id
        end
        inflow = candidates.find { |candidate| outflow.operation_id && candidate.operation_id == outflow.operation_id }
        inflow ||= candidates.first if outflow.transfer
        next unless inflow

        dropped << outflow.external_id << inflow.external_id
      end

      entries.reject { |entry| dropped.include?(entry.external_id) }
    end

    # Each portfolio with its value in the account currency, for those
    # valued at all.
    def valued_goals
      @valued_goals ||= goals.filter_map do |goal|
        series = Series.new(nav_points(goal, currency), ends: closed?(goal))
        [ goal, series ] unless series.empty?
      end
    end

    def series_for(goal)
      valued_goals.find { |valued, _| valued["id"] == goal["id"] }&.last
    end

    # The account's value is the sum of its portfolios' values.
    def navs
      @navs ||= valued_goals.map(&:last)
    end

    # The earliest of the latest days every open portfolio is valued on, so
    # each one's value is known on it. A closed portfolio does not cap it,
    # nor does one StashAway did not serve detail for: its last known value
    # carries forward. Without an open portfolio served, the latest day any
    # portfolio is valued on, a closed one's being the day after or its
    # latest stored row, whichever is later (capped at today, where it is
    # worth 0), so no stored row of a portfolio carried forward falls after
    # it: a closing withdrawal dated after the last value is booked rather
    # than left waiting on a value that will never come.
    def last_nav_date
      @last_nav_date ||= begin
        open = valued_goals.select { |goal, _| open_and_available?(goal) }.map { |_, series| series.last }

        if open.any?
          open.min
        else
          valued_goals.map do |goal, series|
            next series.last unless closed?(goal)

            [ [ series.last.next_day, latest_row_date(goal) ].compact.max, Date.current ].min
          end.max
        end
      end
    end

    # The date of a portfolio's latest completed stored row, if any.
    def latest_row_date(goal)
      Array(goal["transactions"]).flat_map do |item|
        next [] unless completed?(item["groupedStatus"])

        Array(item["transactions"]).filter_map do |row|
          self.class.parse_date(item["groupedDate"].presence || row["date"]) if completed?(row["transactionStatus"])
        end
      end.max
    end

    def first_nav_date
      @first_nav_date ||= navs.map(&:first).min
    end

    def nav_at(date)
      round2(navs.sum(BigDecimal("0")) { |series| series.at(date) })
    end

    def return_adjustments(entries)
      ledger = ledger_rows(entries)
      first = start || [ first_nav_date, ledger.first&.date ].compact.min
      return [] if first > last_nav_date

      # The balance the ledger's rows reach, from the account's own balance
      # when the import appends to earlier history.
      booked = start ? base : BigDecimal("0")
      remaining = ledger.dup
      adjustments = []

      month = first.beginning_of_month
      while month <= last_nav_date
        month_end = month.end_of_month
        period_end = [ month_end, last_nav_date ].min
        booked -= remaining.shift.amount while remaining.any? && remaining.first.date <= period_end

        external_id = "ret:#{month.strftime("%Y-%m")}"
        # A returns row the user froze stands as counted above; the return
        # it does not cover rolls into the next month's row.
        unless protected_by_id.key?(external_id)
          returns = round2(nav_at(period_end) - booked)
          if returns.abs >= HALF_CENT
            key = period_end == month_end ? "returns_month_end" : "returns_month_to_date"
            adjustments << PlannedEntry.new(
              external_id: external_id,
              date: period_end,
              amount: -returns,
              name: I18n.t("stashaway_items.entries.#{key}", month: month.strftime("%Y-%m")),
              category: CATEGORY_RETURNS,
              kind: :returns,
              activity_label: nil,
              goal_id: nil
            )
            booked += returns
          end
        end

        month = month.next_month
      end

      adjustments
    end

    # What the ledger holds for the planned period once the plan is applied:
    # the planned rows, a protected one at its own date and amount, plus the
    # protected rows the plan no longer has. Protected rows before `start`
    # are part of the base already.
    def ledger_rows(entries)
      planned_ids = entries.map(&:external_id).to_set
      rows = entries.map { |entry| protected_by_id.fetch(entry.external_id, entry) }
      rows += protected.reject { |row| planned_ids.include?(row.external_id) || (start && row.date < start) }
      rows.sort_by(&:date)
    end

    def protected_by_id
      @protected_by_id ||= protected.index_by(&:external_id)
    end

    # By date, a day's returns adjustment after its other rows.
    def in_date_order(entries)
      entries.each_with_index.sort_by { |entry, index| [ entry.date, entry.kind == :returns ? 1 : 0, index ] }.map(&:first)
    end
end
