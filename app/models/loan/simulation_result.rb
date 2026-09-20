class Loan
  # Immutable result of one Loan::Simulator run.
  #
  # The simulator is deliberately independent of persistence: this is what a
  # live schedule -- and later a payoff projection -- reads from, rather than
  # each caller deciding for itself what a run produced.
  #
  # There is no "did it converge?" here, because in this engine it always does:
  # the simulator sizes its own level payment from the balance and the periods
  # remaining, and settles the final period exactly. A run that ends with a
  # balance outstanding only becomes possible once a caller can impose a
  # payment the simulator did not choose -- and that belongs with the change
  # that introduces it, not as unreachable state carried in advance.
  class SimulationResult
    attr_reader :payments, :total_interest

    def initialize(payments:, currency_precision:)
      @payments = deep_freeze(payments)
      @total_interest = @payments.sum(BigDecimal("0")) { |p| p[:interest_payment] }
        .round(currency_precision).freeze
      freeze
    end

    def payoff_date
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
