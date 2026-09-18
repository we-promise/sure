# frozen_string_literal: true

# How a loan's interest is measured against a year.
#
# The default is `thirty_360` because it IS what the engine already charges:
# 30/360 reduces to a flat 1/12 exactly, so every existing loan keeps the
# schedule it had, row for row. `actual/actual` would NOT have done -- it
# charges 31/365 in January and 28/365 in February, and only reaches 1/12 when
# a whole calendar year is summed -- so choosing it as the default would have
# silently restated every schedule in the product.
#
# A plain string with a check constraint, matching `securities.kind`
# (`chk_securities_kind`): adding a convention later is a constraint swap, not
# a type change.
class AddDayCountConventionToLoans < ActiveRecord::Migration[8.1]
  CONVENTIONS = %w[thirty_360 actual_365 actual_actual].freeze
  CONSTRAINT = "chk_loans_day_count_convention"

  def up
    add_column :loans, :day_count_convention, :string,
      null: false, default: "thirty_360", if_not_exists: true

    return if check_constraint_exists?(:loans, name: CONSTRAINT)

    add_check_constraint :loans,
      "day_count_convention IN (#{CONVENTIONS.map { |v| "'#{v}'" }.join(', ')})",
      name: CONSTRAINT
  end

  def down
    remove_check_constraint :loans, name: CONSTRAINT, if_exists: true
    remove_column :loans, :day_count_convention, if_exists: true
  end
end
