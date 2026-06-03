# v1 static tax model: returns the fraction of gross pension income kept
# after tax. Replaceable in v2 by a bracket engine behind the same
# net_rate / net_at interface.
module Retirement
  module Tax
    class StaticRate
      # German statutory pension (GRV) Besteuerungsanteil rises with the
      # retirement-start cohort, so the kept fraction falls over time. v1
      # linearly approximates the schedule between these anchor years; v2
      # uses the exact per-cohort table.
      DE_RENTEN_FROM_YEAR = 2025
      DE_RENTEN_TO_YEAR = 2058
      DE_RENTEN_FROM_RATE = 0.82
      DE_RENTEN_TO_RATE = 0.65

      class << self
        # @return [Float] fraction (0..1) of gross income kept after tax
        def net_rate(tax_treatment, retire_year:)
          treatment = tax_treatment.to_s
          return de_renten_rate(retire_year) if treatment == "de_renten"

          RETIREMENT_TAX_STATIC.fetch(treatment) do
            raise ArgumentError, "Unknown tax_treatment: #{treatment.inspect}"
          end
        end

        # @return [Numeric] net (kept) portion of a gross amount
        def net_at(gross_amount, tax_treatment, retire_year:)
          gross_amount.to_d * net_rate(tax_treatment, retire_year:).to_d
        end

        private
          def de_renten_rate(retire_year)
            year = retire_year.to_i.clamp(DE_RENTEN_FROM_YEAR, DE_RENTEN_TO_YEAR)
            span_years = DE_RENTEN_TO_YEAR - DE_RENTEN_FROM_YEAR
            span_rate = DE_RENTEN_FROM_RATE - DE_RENTEN_TO_RATE
            DE_RENTEN_FROM_RATE - ((year - DE_RENTEN_FROM_YEAR).to_f / span_years) * span_rate
          end
      end
    end
  end
end
