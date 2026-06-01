class RetirementConfig
  module PensionCalculator
    class Base
      attr_reader :config

      def initialize(config)
        @config = config
      end

      def estimated_monthly_pension
        raise NotImplementedError, "#{self.class} must implement #estimated_monthly_pension"
      end

      # Override in subclasses to define system-specific parameters for forms
      # Returns array of hashes: [{ key:, type:, label_i18n:, default:, step:, min:, max: }]
      def self.param_definitions
        []
      end

      # Override in subclasses that use a points-based system
      def points_based?
        false
      end

      private

        def pension_param(key)
          config.pension_params&.dig(key.to_s)
        end

        def latest_entry
          config.send(:latest_pension_entry)
        end
    end
  end
end
