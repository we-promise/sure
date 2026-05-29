module Retirement
  module Fire
    # A pension income stream, normalised for the forecast stepper. All
    # amounts are annual, in the plan's currency / today's money. Tax is
    # applied by the stepper via Retirement::Tax::StaticRate, so the income
    # returned here is GROSS.
    class Payout
      SHAPES = %w[monthly_for_life monthly_fixed_term lump_sum lump_plus_annuity].freeze

      attr_reader :kind, :shape, :tax_treatment, :start_age, :end_age,
                  :monthly_amount, :lump_amount

      def self.from_source(source)
        new(
          kind: source.kind,
          shape: source.payout_shape,
          tax_treatment: source.tax_treatment,
          start_age: source.start_age,
          end_age: source.end_age,
          monthly_amount: source.amount.to_d,
          lump_amount: source.params.fetch("lump_amount", 0).to_d
        )
      end

      def initialize(kind:, shape:, tax_treatment:, start_age:, end_age: nil, monthly_amount: 0, lump_amount: 0)
        @kind = kind.to_s
        @shape = shape.to_s
        @tax_treatment = tax_treatment.to_s
        @start_age = start_age
        @end_age = end_age
        @monthly_amount = monthly_amount.to_d
        @lump_amount = lump_amount.to_d
      end

      # Gross annual income + one-time portfolio delta (lump) at a given age.
      # @return [Hash] { income:, portfolio_delta: }
      def contribute_at(age)
        case shape
        when "monthly_for_life"
          { income: age >= start_age ? monthly_amount * 12 : 0.to_d, portfolio_delta: 0.to_d }
        when "monthly_fixed_term"
          active = age >= start_age && (end_age.nil? || age < end_age)
          { income: active ? monthly_amount * 12 : 0.to_d, portfolio_delta: 0.to_d }
        when "lump_sum"
          # `monthly_amount` carries the one-time lump for this shape.
          { income: 0.to_d, portfolio_delta: age == start_age ? monthly_amount : 0.to_d }
        when "lump_plus_annuity"
          { income: age >= start_age ? monthly_amount * 12 : 0.to_d,
            portfolio_delta: age == start_age ? lump_amount : 0.to_d }
        else
          { income: 0.to_d, portfolio_delta: 0.to_d }
        end
      end
    end
  end
end
