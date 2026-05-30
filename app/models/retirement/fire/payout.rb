module Retirement
  module Fire
    # A pension income stream, normalised for the forecast stepper. All
    # amounts are annual, in the plan's currency / today's money. Use
    # #net_rate to apply tax — it honours a source's effective_rate_override
    # and otherwise falls back to Retirement::Tax::StaticRate.
    class Payout
      SHAPES = %w[monthly_for_life monthly_fixed_term lump_sum lump_plus_annuity].freeze

      attr_reader :kind, :shape, :tax_treatment, :start_age, :end_age,
                  :monthly_amount, :lump_amount, :effective_rate_override

      def self.from_source(source)
        new(
          kind: source.kind,
          shape: source.payout_shape,
          tax_treatment: source.tax_treatment,
          start_age: source.start_age,
          end_age: source.end_age,
          monthly_amount: source.amount.to_d,
          lump_amount: source.params.fetch("lump_amount", 0).to_d,
          effective_rate_override: source.effective_rate_override
        )
      end

      def initialize(kind:, shape:, tax_treatment:, start_age:, end_age: nil, monthly_amount: 0, lump_amount: 0, effective_rate_override: nil)
        @kind = kind.to_s
        @shape = shape.to_s
        @tax_treatment = tax_treatment.to_s
        @start_age = start_age
        @end_age = end_age
        @monthly_amount = monthly_amount.to_d
        @lump_amount = lump_amount.to_d
        @effective_rate_override = effective_rate_override
      end

      # Fraction of gross income kept after tax: the user's per-source
      # override when set, otherwise the static rate for the treatment.
      def net_rate(retire_year)
        return effective_rate_override.to_d unless effective_rate_override.nil?

        Retirement::Tax::StaticRate.net_rate(tax_treatment, retire_year: retire_year)
      end

      # Net (after-tax) annual income at a given age.
      def net_income_at(age, retire_year)
        contribute_at(age)[:income].to_d * net_rate(retire_year)
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
