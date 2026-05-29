module Retirement
  module Fire
    # An age-bounded change to the annual spending target, in today's money.
    # Signed: negative reduces the target (e.g. mortgage paid off), positive
    # raises it (e.g. higher healthcare).
    Adjustment = Data.define(:from_age, :to_age, :annual_amount) do
      def applicable_at?(age)
        return false if age < from_age
        to_age.nil? || age <= to_age
      end
    end
  end
end
