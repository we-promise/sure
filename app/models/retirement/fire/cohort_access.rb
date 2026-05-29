module Retirement
  module Fire
    # Earliest age a source's funds can be accessed without penalty. Cohort
    # rules: UK NMPA 55 -> 57 from 2028; US 59.5 for 401k/IRA, 62 for SS;
    # DE 63 for GRV early, 55 otherwise.
    module CohortAccess
      module_function

      def min_access_age(country:, pension_system:, birth_year:, protected_pre_2021: false, override: nil)
        return override if override

        case country.to_s
        when "UK"
          return 55 if protected_pre_2021
          (birth_year.to_i + 57) < 2028 ? 55 : 57
        when "US"
          pension_system.to_s == "us_ss" ? 62 : 59.5
        when "DE"
          pension_system.to_s == "de_grv" ? 63 : 55
        else
          55
        end
      end
    end
  end
end
