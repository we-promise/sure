class Loan
  # The series the loan balance chart draws, and the figures its accessible
  # description quotes.
  #
  #   actual     the recorded balances, origination -> today (or the period's
  #              end, whichever is earlier). Solid: this is fact.
  #   scheduled  the original contract, origination -> maturity. Dashed.
  #   projected  where today's recorded balance is heading on the contract's
  #              repayment. Dashed. Extra payments the borrower has already
  #              made are in here without being named: they are why today's
  #              balance is what it is.
  #
  # The period governs the x-domain (#100, decision 4). Under "All" the domain
  # runs origination -> the later payoff date so every series has room; under
  # any other period it is the period itself, the forward series fall outside
  # it, and the chart shows recorded against scheduled history. `Period` is not
  # touched to achieve this: the payload carries the domain and the controller
  # draws to it.
  #
  # The actual series is never queried past today. Balance::ChartSeriesBuilder
  # carries the last observation forward, so asking it for future dates would
  # draw a flat line asserting the balance never moves again.
  class PayoffChart
    SERIES = %i[actual scheduled projected].freeze

    def initialize(loan, as_of: Date.current, period: nil)
      @loan = loan
      @as_of = as_of
      @period = period
    end

    # nil when there is nothing to draw. The page falls back to the plain
    # balance chart, so the chart's absence is not the page's absence.
    def payload
      return nil unless schedule&.payments&.any?

      series = {
        actual: actual_series,
        scheduled: scheduled_series,
        projected: projection_series(projection)
      }

      {
        today: as_of.iso8601,
        # The tooltip formats dates and money in this locale. The layout
        # hard-codes `lang="en"`, so the document cannot tell the chart.
        locale: I18n.locale.to_s,
        currency: currency,
        domain_start: domain_start.iso8601,
        domain_end: domain_end.iso8601,
        **series,
        visible: SERIES.select { |key| visible?(series[key]) },
        scheduled_payoff_date: schedule.payoff_date&.iso8601,
        projected_payoff_date: projection.payoff_date&.iso8601,
        # The figures the cards beside the chart quote. nil when the projection
        # cannot run or never clears the balance, so a card is not shown for a
        # comparison that does not exist.
        months_saved: projection.converged? ? projection.months_saved : nil,
        interest_saved: projection.converged? ? projection.interest_saved.amount.to_f : nil,
        # What the contracted repayment leaves owing at the original maturity
        # when it does not clear the balance; nil when it does. The one figure
        # the not-converged notice can quote.
        balloon: projection.applicable? && !projection.converged? ? projection.balloon_amount.amount.to_f : nil,
        rows: table_rows(series),
        labels: labels,
        aria_description: aria_description
      }
    end

    private
      attr_reader :loan, :as_of, :period

      def schedule
        @schedule ||= loan.amortization_schedule
      end

      def projection
        @projection ||= loan.payoff_projection(as_of: as_of)
      end

      def currency
        loan.account.currency
      end

      # No period, or the "All" period, means the loan's whole life. Upstream's
      # "All" starts at the family's oldest entry, which for a loan younger than
      # the family is years before it existed; the domain starts at origination
      # instead, and the actual series is clipped there too.
      def whole_life?
        period.nil? || period.key.to_s == "all_time"
      end

      # Memoised, as is domain_end: visible? and table_rows read the domain for
      # every point, and a loan with no start date finds its origination through
      # the account's first valuation, which is a lookup each time it is asked.
      def domain_start
        @domain_start ||= whole_life? ? loan.origination_date : period.start_date
      end

      # Under "All", far enough to hold every line: the contract's payoff and
      # the projection's, whichever is later, and never before today.
      def domain_end
        @domain_end ||= if whole_life?
          [ schedule.payoff_date, projection.payoff_date, as_of ].compact.max
        else
          period.end_date
        end
      end

      # Recorded balances from the domain's start to today, or to the period's
      # end when that comes first (Last Month must stay inside its own window).
      # Nothing before origination, and nothing before the first materialised
      # balance: the series builder carries the last observation forward and
      # reports zero before there is one, and a flat zero lead-in reads as a
      # balance that was not there.
      def actual_series
        first_balance_date = loan.account.balances.minimum(:date)
        return [] if first_balance_date.nil?

        from = [ domain_start, loan.origination_date, first_balance_date ].compact.max
        to = [ period&.end_date, as_of ].compact.min
        return [] if from > to

        loan.account.balance_series(period: Period.custom(start_date: from, end_date: to)).values.map do |value|
          { date: value.date.iso8601, balance: value.value.amount.to_f }
        end
      end

      # Opens at origination with the full principal. Starting at the first
      # payment omits the amount borrowed entirely, and leaves a one-payment
      # loan with a single point and therefore no line at all.
      def scheduled_series
        rows = schedule.payments
        return [] if rows.empty?

        opening = { date: loan.origination_date.iso8601, balance: schedule.principal.to_f }
        [ opening ] + series(rows) { |p| [ p.date, p.ending_balance.amount ] }
      end

      # A projection opens at today's real balance, so the line starts there
      # rather than at its first payment -- otherwise it appears to begin
      # wherever the first payment happens to leave it.
      def projection_series(source)
        return [] unless source&.applicable?

        opening = { date: as_of.iso8601, balance: source.current_balance.amount.to_f }
        [ opening ] + series(source.payments) { |p| [ p[:payment_date], p[:ending_balance] ] }
      end

      def series(rows)
        rows.map do |row|
          date, balance = yield(row)
          { date: date.iso8601, balance: balance.to_f }
        end
      end

      # A series is worth a legend entry when it draws a line inside the
      # domain: two of its points fall inside, or it enters on one side and
      # leaves on the other. One point on the boundary -- the projection's
      # opening point sits exactly on the end of every period but "All" -- is
      # not a line, and the legend must not promise one.
      def visible?(points)
        dates = points.map { |point| Date.iso8601(point[:date]) }
        return false if dates.empty?

        inside = dates.count { |date| date.between?(domain_start, domain_end) }
        inside >= 2 || (dates.first < domain_start && dates.last > domain_end)
      end

      # The accessible data alternative (gate G6): one row per scheduled date
      # inside the domain, carrying the recorded balance on or before that
      # date, the schedule's balance, and the projection's. Built here so the
      # table and the chart cannot disagree about a single figure.
      def table_rows(series)
        # Oldest first, as the series builder emits it, so each row can find
        # the latest recorded balance on or before its date by binary search
        # rather than a scan per row.
        actual = series[:actual].map { |p| [ Date.iso8601(p[:date]), p[:balance] ] }
        projected = series[:projected].to_h { |p| [ p[:date], p[:balance] ] }

        series[:scheduled].filter_map do |point|
          date = Date.iso8601(point[:date])
          next unless date.between?(domain_start, domain_end)

          recorded = latest_recorded_on_or_before(actual, date) if date <= as_of
          {
            date: point[:date],
            actual: recorded&.last,
            scheduled: point[:balance],
            projected: projected[point[:date]]
          }
        end
      end

      # The last [date, balance] pair dated on or before `date`, from a list
      # sorted by date; nil when every recorded point is later.
      def latest_recorded_on_or_before(actual, date)
        first_after = actual.bsearch_index { |recorded_on, _| recorded_on > date } || actual.length
        actual[first_after - 1] if first_after.positive?
      end

      def labels
        SERIES.index_with { |key| I18n.t("UI.account.chart.loan.#{key}") }
          .merge(today: I18n.t("UI.account.chart.loan.today"))
      end

      # Every series the chart draws is named here, with its payoff date.
      def aria_description
        I18n.t(
          "UI.account.chart.loan.aria_description",
          current_balance: projection.current_balance.format,
          scheduled_payoff_date: long_date(schedule.payoff_date, I18n.t("loans.tabs.overview.unknown")),
          projected_payoff_date: long_date(projection.payoff_date, I18n.t("UI.account.chart.loan.no_payoff"))
        )
      end

      def long_date(date, fallback)
        date ? I18n.l(date, format: :long) : fallback
      end
  end
end
