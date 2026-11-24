# frozen_string_literal: true

# How often a loan's stated rate compounds.
#
# The default is `per_period` because it IS what the engine already charges:
# the annual rate divided by twelve for a month, so every existing loan keeps
# the schedule it had, row for row. `semi_annual` and `annual` are for
# contracts that state the rate compounded half-yearly or yearly, such as
# Canadian fixed-rate mortgages.
#
# A plain string with a check constraint, as `day_count_convention` is: adding
# a compounding later is a constraint swap, not a type change.
class AddInterestCompoundingToLoans < ActiveRecord::Migration[8.1]
  COMPOUNDINGS = %w[per_period semi_annual annual].freeze
  CONSTRAINT = "chk_loans_interest_compounding"

  def change
    add_column :loans, :interest_compounding, :string,
      null: false, default: "per_period"

    add_check_constraint :loans,
      "interest_compounding IN (#{COMPOUNDINGS.map { |v| "'#{v}'" }.join(', ')})",
      name: CONSTRAINT
  end
end
