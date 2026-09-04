class Loan
  # Resolves the contracted rate without making Loan::Simulator depend on the
  # Loan model. A fixed-rate resolver is a constant callable; variable loans
  # delegate date lookup to Loan#current_variable_rate.
  class RateResolver
    def self.for(loan)
      new(loan)
    end

    def initialize(loan)
      @loan = loan
    end

    def accrual_rate_for(date)
      return loan.interest_rate unless loan.rate_type == "variable"
      loan.current_variable_rate(date)
    end

    def re_amortisation_events(from_date, to_date)
      return [] unless loan.rate_type == "variable"

      loan.variable_rates.filter_map do |date, rate|
        effective_date = Date.iso8601(date.to_s)
        next unless effective_date >= from_date && effective_date <= to_date

        { date: effective_date, rate: rate }
      end
    end

    private

      attr_reader :loan
  end
end
