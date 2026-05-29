module Retirement
  module Fire
    # Output of Retirement::Fire::Forecast. glide is [[age, portfolio], ...]
    # in today's money; income_by_year holds the drawdown breakdown.
    ForecastResult = Data.define(
      :glide,
      :income_by_year,
      :money_lasts_to_age,
      :terminal_value,
      :coast_age,
      :feasible,
      :warnings
    ) do
      def lasts_past_terminal?
        money_lasts_to_age >= terminal_age
      end

      def terminal_age
        glide.last.first
      end

      def portfolio_at_retirement(retire_age)
        glide.find { |age, _| age == retire_age }&.last
      end
    end
  end
end
