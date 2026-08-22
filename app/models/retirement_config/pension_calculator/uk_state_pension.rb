class RetirementConfig
  module PensionCalculator
    class UkStatePension < Base
      FULL_WEEKLY_RATE = 221.20 # £/week as of 2025/26

      def estimated_monthly_pension
        if latest_entry&.projected_monthly_pension
          return latest_entry.projected_monthly_pension
        end

        qualifying_years = pension_param("qualifying_years")&.to_f || 0
        rate = pension_param("full_weekly_rate")&.to_f || FULL_WEEKLY_RATE

        return 0 if qualifying_years <= 0
        (qualifying_years / 35.0) * rate * 52 / 12
      end

      def self.param_definitions
        [
          { key: "qualifying_years", type: :integer, min: 0, max: 50, default: 0 },
          { key: "full_weekly_rate", type: :number, step: 0.01, min: 0, default: FULL_WEEKLY_RATE }
        ]
      end
    end
  end
end
