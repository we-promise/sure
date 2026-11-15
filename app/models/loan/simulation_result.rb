class Loan
  # Immutable result of one Loan::Simulator run.
  #
  # The simulator is deliberately independent of persistence: this is what a
  # live schedule -- and later a payoff projection -- reads from, rather than
  # each caller deciding for itself what a run produced.
  #
  # A run does not always clear the balance. It does whenever the simulator
  # sizes its own payment, but a caller can impose one it did not choose -- a
  # projection holds the CONTRACTED repayment against today's balance -- and
  # against a balance that has grown, the contracted repayment may not be
  # enough. That leaves a balloon, and #payoff_date refuses to give a date for
  # a loan that was never paid off.
  class SimulationResult
    attr_reader :payments, :balloon_amount, :total_interest

    def initialize(payments:, currency_precision:, converged: true, balloon_amount: BigDecimal("0"))
      @converged = converged
      @balloon_amount = BigDecimal(balloon_amount.to_s).round(currency_precision).freeze
      @payments = deep_freeze(payments)
      @total_interest = @payments.sum(BigDecimal("0")) { |p| p[:interest_payment] }
        .round(currency_precision).freeze
      freeze
    end

    def converged?
      @converged
    end

    # nil for a run that ended with a balance outstanding. A balloon quoted as
    # a payoff date is the reading that costs someone money.
    def payoff_date
      return nil unless converged?

      payments.last&.fetch(:payment_date)
    end

    def payment_count
      payments.length
    end

    private
      def deep_freeze(value)
        case value
        when Array then value.map { |item| deep_freeze(item) }.freeze
        when Hash  then value.transform_values { |item| deep_freeze(item) }.freeze
        else value.freeze
        end
      end
  end
end
