class RetirementConfig
  module PensionCalculator
    class UsSocialSecurity < Base
      def estimated_monthly_pension
        if latest_entry&.projected_monthly_pension
          return latest_entry.projected_monthly_pension
        end

        # Users enter their estimated benefit from their SSA statement
        pension_param("estimated_monthly_benefit")&.to_f || 0
      end

      def self.param_definitions
        [
          { key: "estimated_monthly_benefit", type: :number, step: 1, min: 0, default: 0 }
        ]
      end
    end
  end
end
