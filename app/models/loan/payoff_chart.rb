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
  # The picked timescale governs the x-domain (#100, decision 4), running
  # forward from origination (owner review of #3474). Under "All" the domain
  # runs origination -> the later payoff date so every series has room; under a
  # window it runs origination -> the window's end, and the forward series show
  # only when that reaches past today. `Period` is not touched to achieve this:
  # the payload carries the domain and the controller draws to it.
  #
  # The actual series is never queried past today. Balance::ChartSeriesBuilder
  # carries the last observation forward, so asking it for future dates would
  # draw a flat line asserting the balance never moves again.
  class PayoffChart
    SERIES = %i[actual scheduled projected].freeze

    # The timescales a loan's chart offers, keyed by the shared Period key the
    # picker saves as the user's default. Each maps the loan's start date and
    # today to where the window ends: M the first month, 90D the first ninety
    # days, YTD origination to today, 1Y, 5Y and 10Y the first years. All has no
    # end and shows the whole life.
    #
    # Only these keys are loan windows. Any other Period key, including one added
    # to Period::PERIODS later, shows the whole life, because the picker's choice
    # is shared with every account page. A test keeps these keys a subset of
    # Period::PERIODS so a renamed period cannot silently stop matching.
    WINDOWS = {
      "current_month" => ->(start, _as_of) { start >> 1 },
      "last_90_days" => ->(start, _as_of) { start + 90 },
      "current_year" => ->(_start, as_of) { as_of },
      "last_365_days" => ->(start, _as_of) { start >> 12 },
      "last_5_years" => ->(start, _as_of) { start >> 60 },
      "last_10_years" => ->(start, _as_of) { start >> 120 },
      "all_time" => nil
    }.freeze

    # [key, label] pairs for the loan chart's period picker, in WINDOWS order.
    def self.window_options
      WINDOWS.keys.map { |key| [ key, I18n.t("UI.account.chart.loan.windows.#{key}") ] }
    end

    # `projection` lets a caller that also shows the forecast elsewhere on the
    # page build it once; it must be the loan's projection for this `as_of`.
    def initialize(loan, as_of: Date.current, period: nil, projection: nil)
      @loan = loan
      @as_of = as_of
      @period = period
      @projection = projection
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
        labels: labels,
        aria_description: aria_description(actual: series[:actual])
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

      # Every window on a loan's chart runs forward from origination rather than
      # back from today (owner review of #3474), so 1Y is the loan's first year.
      # No period, "All", and any period the loan chart does not offer -- the
      # picker's choice is shared with every account -- mean the whole life.
      # Upstream's "All" starts at the family's oldest entry, which for a loan
      # younger than the family is years before it existed.
      def whole_life?
        window_end.nil?
      end

      # Where the chosen window ends, before it is capped at the whole life's
      # end; nil for the whole life.
      def window_end
        return @window_end if defined?(@window_end)

        @window_end = period && WINDOWS[period.key.to_s]&.call(loan.origination_date, as_of)
      end

      # Memoised, as is domain_end: visible? reads the domain for every point,
      # and a loan with no start date finds its origination through the
      # account's first valuation, which is a lookup each time it is asked.
      def domain_start
        @domain_start ||= loan.origination_date
      end

      # The whole life reaches far enough to hold every line: the contract's
      # payoff and the projection's, whichever is later, and never before today.
      # A window ends where it ends, but never past that and never on its start.
      def domain_end
        @domain_end ||= begin
          whole_life_end = [ schedule.payoff_date, projection.payoff_date, as_of ].compact.max
          whole_life? ? whole_life_end : [ [ window_end, whole_life_end ].min, domain_start + 1 ].max
        end
      end

      # Recorded balances from origination to today, or to the window's end when
      # that comes first. Nothing before the first materialised balance: the
      # series builder carries the last observation forward and reports zero
      # before there is one, and a flat zero lead-in reads as a balance that
      # was not there.
      def actual_series
        first_balance_date = loan.account.balances.minimum(:date)
        return [] if first_balance_date.nil?

        from = [ domain_start, first_balance_date ].compact.max
        to = [ domain_end, as_of ].min
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

      # The chart controller reads `interactive_chart` for the SVG's
      # aria-roledescription; without it every locale gets its English default.
      def labels
        SERIES.index_with { |key| I18n.t("UI.account.chart.loan.#{key}") }
          .merge(
            today: I18n.t("UI.account.chart.loan.today"),
            interactive_chart: I18n.t("UI.account.chart.loan.interactive_chart")
          )
      end

      # Every series the chart draws is named here, with its payoff date.
      def aria_description(actual:)
        description = I18n.t(
          "UI.account.chart.loan.aria_description",
          current_balance: projection.current_balance.format,
          scheduled_payoff_date: long_date(schedule.payoff_date, I18n.t("loans.tabs.overview.unknown")),
          projected_payoff_date: long_date(projection.payoff_date, I18n.t("UI.account.chart.loan.no_payoff"))
        )

        actual_start_date = actual.first && Date.iso8601(actual.first[:date])
        if actual_start_date && actual_start_date > domain_start
          description = [ description, I18n.t(
            "UI.account.chart.loan.aria_actual_history_starts",
            date: I18n.l(actual_start_date, format: :long)
          ) ].join(" ")
        end

        description
      end

      def long_date(date, fallback)
        date ? I18n.l(date, format: :long) : fallback
      end
  end
end
