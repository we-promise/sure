class IncomeStatement
  # Monthly spend per category over a long window, with the direction of travel.
  #
  # A single month tells an assistant almost nothing: it cannot distinguish an
  # unusual month from a habit that has been drifting for a year. The useful
  # statement is not "you spent 300 on restaurants" but "restaurant spending
  # went from 150 to 300 a month over eight months", and that needs a series.
  #
  # Direction is reported two ways on purpose. The slope is sensitive to a
  # single outlier month; the half-over-half comparison is not, and is what a
  # person would compute by eye. When they disagree, the drift is not real.
  class CategoryTrends
    DEFAULT_MONTHS = 12
    MAX_MONTHS = 24

    Series = Data.define(:category, :values, :total, :average, :slope_per_month, :first_half_average, :second_half_average) do
      # Percent change between the two halves. nil rather than infinity when
      # the category was untouched in the first half: "up 100%" from zero is
      # not a meaningful number to read aloud.
      def change_pct
        return nil if first_half_average.zero?

        (((second_half_average - first_half_average) / first_half_average) * 100).round(1)
      end

      # A label only where the two measures agree. Requiring both is what stops
      # one holiday month from being reported as a trend.
      def direction
        return "flat" if slope_per_month.abs < 1

        change = change_pct
        return "unclear" if change.nil?

        if slope_per_month.positive? && change > 10
          "rising"
        elsif slope_per_month.negative? && change < -10
          "falling"
        else
          "unclear"
        end
      end
    end

    def initialize(family, user: nil, months: DEFAULT_MONTHS, classification: "expense")
      @family = family
      @user = user
      @months = months.to_i.clamp(1, MAX_MONTHS)
      @classification = classification == "income" ? "income" : "expense"
    end

    attr_reader :months, :classification

    # The window ends on the last COMPLETE month. Including the current one
    # would weigh a handful of elapsed days against full months: on the 3rd of
    # a month that reads as spending collapsing, which both halves of the
    # direction test agree on, so a manufactured "falling" is reported with the
    # same confidence as a real one (and a genuine rise is masked the same way).
    def periods
      @periods ||= begin
        last_complete = Date.current.beginning_of_month.prev_month
        (0...months).map do |offset|
          month = last_complete.advance(months: -(months - 1 - offset))
          Period.custom(start_date: month, end_date: month.end_of_month)
        end
      end
    end

    def month_labels
      periods.map { |period| period.start_date.strftime("%Y-%m") }
    end

    def series
      @series ||= begin
        by_category = Hash.new { |hash, key| hash[key] = [] }

        # One grouped query for the whole window rather than one per month.
        monthly = income_statement.monthly_category_totals(classification: classification, periods: periods)

        periods.each_with_index do |period, index|
          totals = monthly[period]

          totals.category_totals.reject { |total| total.category.subcategory? }.each do |total|
            values = (by_category[total.category.name] ||= Array.new(periods.size, 0.to_d))
            values[index] = total.total.to_d.round(2)
          end
        end

        by_category.map { |name, values| build_series(name, values) }
                   .sort_by { |entry| -entry.total }
      end
    end

    private
      def income_statement
        @income_statement ||= IncomeStatement.new(@family, user: @user)
      end

      def build_series(name, values)
        half = values.size / 2
        first_half = values.first(half)
        second_half = values.last(values.size - half)

        Series.new(
          category: name,
          values: values,
          total: values.sum.round(2),
          average: (values.sum / values.size).round(2),
          slope_per_month: slope(values).round(2),
          first_half_average: first_half.empty? ? 0.to_d : (first_half.sum / first_half.size).round(2),
          second_half_average: second_half.empty? ? 0.to_d : (second_half.sum / second_half.size).round(2)
        )
      end

      # Ordinary least squares against the month index. Reported per month,
      # which is the unit a person can act on ("about 20 more each month").
      def slope(values)
        n = values.size
        return 0.to_d if n < 2

        mean_x = (n - 1) / 2.0
        mean_y = values.sum / n

        numerator = values.each_with_index.sum { |value, index| (index - mean_x) * (value - mean_y) }
        denominator = (0...n).sum { |index| (index - mean_x)**2 }

        return 0.to_d if denominator.zero?

        (numerator / denominator).to_d
      end
  end
end
