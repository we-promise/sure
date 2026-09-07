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
      return loan.interest_rate unless loan.variable_rate_type?
      loan.current_variable_rate(date)
    end

    # The ACCRUAL clock (contract C7): rate changes take effect on their own
    # effective date, mid-cycle included.
    #
    # Deliberately separate from #re_amortisation_events. Both read the same
    # variable_rate_schedule for this loan, but they answer different
    # questions, and Loan::Simulator must be able to be handed different
    # answers -- a rate that moves accrual without moving the contracted
    # repayment is exactly what C7/C8 describe, and it was unrepresentable
    # while accrual segmented on re-amortisation events (#25).
    def accrual_rate_changes(from_date, to_date)
      return [] unless loan.variable_rate_type?

      loan.variable_rates.filter_map do |date, rate|
        effective_date = Date.iso8601(date.to_s)
        next unless effective_date >= from_date && effective_date < to_date

        { date: effective_date, rate: rate }
      end.sort_by { |change| change.fetch(:date) }
    end

    # The PAYMENT clock (contract C8): a rate change resizes the minimum
    # repayment from the next contractual payment date, not from its own
    # effective date.
    def re_amortisation_events(from_date, to_date)
      return [] unless loan.variable_rate_type?

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
