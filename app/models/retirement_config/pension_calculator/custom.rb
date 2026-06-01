class RetirementConfig
  module PensionCalculator
    class Custom < Base
      def estimated_monthly_pension
        latest_entry&.projected_monthly_pension || 0
      end
    end
  end
end
