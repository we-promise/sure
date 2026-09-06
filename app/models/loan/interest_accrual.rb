class Loan
  # Calculates interest over a date range without rounding intermediate
  # segments. Dates are half-open: interest accrues for from_date up to, but
  # not including, to_date. An offset change is effective on its date.
  class InterestAccrual
    DEFAULT_DAY_COUNT_CONVENTION = :actual_365
    DAY_COUNT_CONVENTIONS = %i[actual_365 actual_actual].freeze
    DAY_COUNT = BigDecimal("365")
    LEAP_YEAR_DAY_COUNT = BigDecimal("366")
    PERCENT = BigDecimal("100")

    def self.calculate(**args)
      new.calculate(**args)
    end

    def self.charge(currency_precision:, **args)
      calculate(**args).round(currency_precision)
    end

    def calculate(
      from_date:, to_date:, balance:, annual_rate:, annual_rate_changes: [], offset_changes: [],
      change_points: [], day_count_convention: DEFAULT_DAY_COUNT_CONVENTION
    )
      validate_dates!(from_date, to_date)
      day_count_convention = normalize_day_count_convention(day_count_convention)

      principal = decimal(balance)
      rate = decimal(annual_rate)
      points = normalize_change_points(change_points, from_date, to_date)
      points = legacy_change_points(offset_changes, annual_rate_changes, from_date, to_date) if points.empty?
      change_dates = calculation_dates(
        from_date: from_date,
        to_date: to_date,
        points: points,
        day_count_convention: day_count_convention
      )
      points_by_date = points.index_by { |point| point.fetch(:date) }
      current_balance = principal
      current_offset = BigDecimal("0")
      current_rate = rate

      change_dates.each_with_index.sum do |segment_start, index|
        segment_end = change_dates[index + 1] || to_date
        days = (segment_end - segment_start).to_i
        if (point = points_by_date[segment_start])
          current_balance = point.fetch(:balance, current_balance)
          current_offset = point.fetch(:offset, current_offset)
          current_rate = point.fetch(:rate, current_rate)
        end
        next BigDecimal("0") if days.zero?

        interest_bearing_balance = [ current_balance - current_offset, BigDecimal("0") ].max
        interest_bearing_balance * days * current_rate / PERCENT /
          day_count_denominator(segment_start, day_count_convention)
      end
    end

    private

      def legacy_change_points(offset_changes, annual_rate_changes, from_date, to_date)
        offsets = normalize_changes(offset_changes, from_date, to_date).to_h
        rates = normalize_changes(annual_rate_changes, from_date, to_date).to_h
        (offsets.keys | rates.keys).sort.map do |date|
          { date: date, offset: offsets[date], rate: rates[date] }.compact
        end
      end

      def normalize_change_points(points, from_date, to_date)
        Array(points).filter_map do |point|
          next unless point.fetch(:date) >= from_date && point.fetch(:date) < to_date

          {
            date: point.fetch(:date),
            balance: point[:balance] && decimal(point[:balance]),
            offset: point[:offset] && decimal(point[:offset]),
            rate: point[:rate] && decimal(point[:rate])
          }.compact
        end.sort_by { |point| point.fetch(:date) }
      end

      def normalize_changes(changes, from_date, to_date)
        normalized = Array(changes).filter_map do |change|
          date, amount = if change.is_a?(Array)
            change
          else
            [ change.fetch(:date), change.fetch(:amount) ]
          end
          next unless date >= from_date && date < to_date

          [ date, decimal(amount) ]
        end.sort_by(&:first)

        normalized.each_with_object([]) do |change, compacted|
          compacted << change unless compacted.last&.last == change.last
        end
      end

      def validate_dates!(from_date, to_date)
        return if from_date <= to_date

        raise ArgumentError, "accrual range must end on or after it starts"
      end

      def calculation_dates(from_date:, to_date:, points:, day_count_convention:)
        dates = [ from_date ] + points.map { |point| point.fetch(:date) }
        if day_count_convention == :actual_actual
          dates.concat((from_date.year + 1...to_date.year + 1).map { |year| Date.new(year, 1, 1) })
        end
        dates.push(to_date).uniq.select { |date| date <= to_date }.sort
      end

      def day_count_denominator(date, day_count_convention)
        return DAY_COUNT unless day_count_convention == :actual_actual

        Date.leap?(date.year) ? LEAP_YEAR_DAY_COUNT : DAY_COUNT
      end

      def normalize_day_count_convention(value)
        convention = value.to_sym
        return convention if DAY_COUNT_CONVENTIONS.include?(convention)

        raise ArgumentError,
          "unsupported day-count convention: #{value.inspect} (expected one of #{DAY_COUNT_CONVENTIONS.join(', ')})"
      rescue NoMethodError
        raise ArgumentError, "unsupported day-count convention: #{value.inspect}"
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "accrual values must be numeric"
      end
  end
end
