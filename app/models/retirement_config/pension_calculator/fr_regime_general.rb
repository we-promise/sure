class RetirementConfig
  module PensionCalculator
    class FrRegimeGeneral < Base
      def estimated_monthly_pension
        if latest_entry&.projected_monthly_pension
          return latest_entry.projected_monthly_pension
        end

        # Users can enter projected pension from their relevé de carrière
        pension_param("estimated_monthly_pension")&.to_f || 0
      end

      def self.param_definitions
        [
          { key: "trimestres", type: :integer, min: 0, max: 200, default: 0 },
          { key: "estimated_monthly_pension", type: :number, step: 1, min: 0, default: 0 }
        ]
      end
    end
  end
end
