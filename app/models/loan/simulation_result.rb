class Loan
  # Immutable result returned by Loan::Simulator. The simulator is deliberately
  # independent of persistence; callers may use this for a live projection or
  # materialise the payment rows through an explicit write path.
  class SimulationResult
    attr_reader :payments, :balloon_amount, :total_interest, :total_cost

    def initialize(payments:, converged:, balloon_amount:, currency_precision:)
      @payments = deep_freeze(payments)
      @converged = converged
      @balloon_amount = balloon_amount.round(currency_precision).freeze
      @total_interest = @payments.sum { |payment| payment[:interest_payment] }.round(currency_precision).freeze
      @total_cost = (@payments.sum { |payment| payment[:payment_amount] } + @balloon_amount).round(currency_precision).freeze
      freeze
    end

    def converged?
      @converged
    end

    def payoff_date
      return nil unless converged?
      payments.last&.fetch(:payment_date)
    end

    def payment_count
      payments.length
    end

    def compare_to(other)
      {
        payment_count: payment_count - other.payment_count,
        total_interest: total_interest - other.total_interest,
        total_cost: total_cost - other.total_cost
      }.freeze
    end

    private

      def deep_freeze(value)
        case value
        when Array
          value.map { |item| deep_freeze(item) }.freeze
        when Hash
          value.transform_values { |item| deep_freeze(item) }.freeze
        else
          value.freeze
        end
      end
  end
end
