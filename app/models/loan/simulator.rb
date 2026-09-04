class Loan
  # Resolver-driven calculation loop. It accepts values and callables rather
  # than a Loan so projections, persisted schedules, and future offset/scenario
  # calculations can share one period engine.
  class Simulator
    MAX_TERM_MONTHS = Loan::MAX_TERM_MONTHS
    EVENT_ORDER = %i[accrual extra_repayment offset_movement payment re_amortisation].freeze

    attr_reader :starting_balance, :starting_balance_as_of, :accrual_start_date,
      :payment_schedule, :payment_strategy

    def initialize(
      starting_balance:,
      starting_balance_as_of:,
      accrual_start_date:,
      payment_schedule:,
      accrual_rate_for:,
      re_amortisation_events:,
      payment_strategy:,
      payment_amount_for:,
      currency_precision:,
      interest_for: nil,
      daily_accrual: false,
      max_iterations: nil,
      extra_for: nil,
      offset_for: nil
    )
      @starting_balance = decimal(starting_balance)
      @starting_balance_as_of = starting_balance_as_of
      @accrual_start_date = accrual_start_date
      @payment_schedule = payment_schedule.to_a.freeze
      @accrual_rate_for = callable!(accrual_rate_for, :accrual_rate_for)
      @re_amortisation_events = callable!(re_amortisation_events, :re_amortisation_events)
      @payment_amount_for = callable!(payment_amount_for, :payment_amount_for)
      @currency_precision = currency_precision
      @daily_accrual = daily_accrual
      @interest_for = interest_for
      @payment_strategy = payment_strategy.to_sym
      @max_iterations = [ max_iterations || @payment_schedule.length, MAX_TERM_MONTHS ].min
      @extra_for = extra_for || ->(_from_date, _to_date) { [] }
      @offset_for = offset_for || ->(_from_date, _to_date) { [] }

      raise ArgumentError, "unsupported payment strategy: #{payment_strategy.inspect}" unless %i[hold reamortize].include?(@payment_strategy)
      raise ArgumentError, "payment schedule must not be empty" if @payment_schedule.empty?
    end

    def run
      balance = starting_balance
      payments = []
      payment_number = 1
      held_payment = nil

      rate_segments.each do |segment|
        remaining_payments = payment_schedule.length - payment_number + 1
        payment = if payment_strategy == :hold
          held_payment ||= payment_amount(segment[:rate], balance, remaining_payments, payment_number)
        else
          payment_amount(segment[:rate], balance, remaining_payments, payment_number)
        end

        segment[:payment_count].times do
          break if balance <= 0 || payment_number > @max_iterations

          payment_date = payment_schedule[payment_number - 1]
          previous_date = payment_number == 1 ? accrual_start_date : payment_schedule[payment_number - 2]
          # These resolvers are intentionally called at the period boundary.
          # Their change-point semantics are used by the daily-accrual and
          # offset extensions; L3 preserves the existing monthly result.
          extra_changes = @extra_for.call(previous_date, payment_date)
          offset_changes = @offset_for.call(previous_date, payment_date)
          monthly_rate = (decimal(segment[:rate]) / BigDecimal("100")) / BigDecimal("12")

          interest = if @interest_for
            @interest_for.call(
              from_date: previous_date,
              to_date: payment_date,
              balance: balance,
              interest_bearing_balance: balance,
              rate: segment[:rate]
            )
          elsif @daily_accrual
            accrual_rate = accrual_rate_at(previous_date, segment[:rate])
            interest, balance = accrue_daily_period(
              from_date: previous_date,
              to_date: payment_date,
              balance: balance,
              annual_rate: accrual_rate,
              annual_rate_changes: rate_changes_between(previous_date, payment_date),
              extra_changes: extra_changes,
              offset_changes: offset_changes
            )
            interest.round(@currency_precision)
          else
            (balance * monthly_rate).round(@currency_precision)
          end

          step = AmortizationMath.step(
            balance: balance,
            payment: payment,
            monthly_rate: monthly_rate,
            currency_precision: @currency_precision,
            final: payment_number == payment_schedule.length,
            interest: interest
          )

          payments << {
            payment_number: payment_number,
            payment_date: payment_date,
            interest_rate: decimal(segment[:rate]),
            **step
          }

          balance = step[:ending_balance]
          payment_number += 1
          break if balance <= 0
        end
      end

      SimulationResult.new(
        payments: payments,
        converged: balance.zero?,
        balloon_amount: balance,
        currency_precision: @currency_precision
      )
    end

    private

      def rate_segments
        segments = []
        re_amortisation_rates = normalized_re_amortisation_rates

        payment_schedule.each do |payment_date|
          rate = re_amortisation_rate_for(payment_date, re_amortisation_rates) || @accrual_rate_for.call(payment_date)
          if segments.last && segments.last[:rate] == rate
            segments.last[:payment_count] += 1
          else
            segments << { rate: rate, start_date: payment_date, end_date: payment_date, payment_count: 1 }
          end
          segments.last[:end_date] = payment_date
        end

        segments
      end

      def normalized_re_amortisation_rates
        @re_amortisation_events.call(payment_schedule.first, payment_schedule.last).filter_map do |event|
          date = event.fetch(:date)
          rate = event.fetch(:rate)
          [ date, decimal(rate) ]
        end.sort_by(&:first)
      end

      def rate_changes_between(from_date, to_date)
        normalized_re_amortisation_rates.filter_map do |date, rate|
          next unless date >= from_date && date < to_date

          { date: date, amount: rate }
        end
      end

      def accrual_rate_at(date, fallback)
        normalized_re_amortisation_rates.reverse_each do |event_date, rate|
          return rate if event_date <= date
        end
        @accrual_rate_for.call(date) || fallback
      end

      def accrue_daily_period(from_date:, to_date:, balance:, annual_rate:, annual_rate_changes:, extra_changes:, offset_changes:)
        extras = normalize_amount_changes(extra_changes, from_date, to_date)
        rates = normalize_amount_changes(annual_rate_changes, from_date, to_date)
        offsets = normalize_amount_changes(offset_changes, from_date, to_date)
        dates = ([ from_date ] + extras.keys + rates.keys + offsets.keys + [ to_date ]).uniq.sort
        interest = BigDecimal("0")
        current_balance = balance
        current_rate = annual_rate
        current_offset = BigDecimal("0")
        change_points = dates.filter_map do |date|
          current_balance -= extras[date] if extras.key?(date)
          current_balance = BigDecimal("0") if current_balance.negative?
          current_rate = rates[date] if rates.key?(date)
          current_offset = offsets[date] if offsets.key?(date)
          next if date == to_date

          { date: date, balance: current_balance, offset: current_offset, rate: current_rate }
        end

        interest = InterestAccrual.calculate(
          from_date: from_date,
          to_date: to_date,
          balance: balance,
          annual_rate: annual_rate,
          change_points: change_points
        )

        [ interest, current_balance ]
      end

      def normalize_amount_changes(changes, from_date, to_date)
        Array(changes).each_with_object({}) do |change, normalized|
          date, amount = change.is_a?(Array) ? change : [ change.fetch(:date), change.fetch(:amount) ]
          next unless date >= from_date && date <= to_date

          normalized[date] = decimal(amount)
        end
      end

      def re_amortisation_rate_for(payment_date, events)
        events.reverse_each do |date, rate|
          return rate if date <= payment_date
        end
        nil
      end

      def payment_amount(rate, balance, remaining_payments, payment_number)
        decimal(@payment_amount_for.call(
          rate: rate,
          balance: balance,
          remaining_payments: remaining_payments,
          payment_number: payment_number
        ))
      end

      def callable!(value, name)
        return value if value.respond_to?(:call)
        raise ArgumentError, "#{name} must be callable"
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "simulation values must be numeric"
      end
  end
end
