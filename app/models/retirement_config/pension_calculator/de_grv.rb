class RetirementConfig
  module PensionCalculator
    class DeGrv < Base
      DEFAULT_RENTENWERT = 39.32

      def estimated_monthly_pension
        if latest_entry&.projected_monthly_pension
          return latest_entry.projected_monthly_pension
        end

        points = total_projected_points
        rw = pension_param("rentenwert")&.to_f || DEFAULT_RENTENWERT
        points * rw
      end

      def points_based?
        true
      end

      def self.param_definitions
        [
          { key: "expected_annual_points", type: :number, step: 0.01, min: 0, default: 1.0 },
          { key: "rentenwert", type: :number, step: 0.01, min: 0, default: DEFAULT_RENTENWERT },
          { key: "contribution_start_year", type: :integer, min: 1960, max: Date.current.year }
        ]
      end

      private

        def total_projected_points
          current = latest_entry&.current_points || 0
          annual = pension_param("expected_annual_points")&.to_f || 1.0
          current + (annual * config.years_to_retirement)
        end
    end
  end
end
