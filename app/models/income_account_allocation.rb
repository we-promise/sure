# Paycheck Flow Planner (M2): one edge from a declared income series to a bank
# account on the family's money map. Modes resolve in priority order when the
# plan is solved (required -> specific -> percent -> leftover); `value` is the
# per-paycheck amount for `specific`, the 0.0-1.0 fraction for `percent`, and
# NULL for the derived `required` / `leftover` edges.
class IncomeAccountAllocation < ApplicationRecord
  enum :mode, { required: "required", specific: "specific", percent: "percent", leftover: "leftover" }

  belongs_to :family
  belongs_to :income_series, class_name: "RecurringTransaction"
  belongs_to :account

  validate :value_matches_mode
  validate :income_series_is_income
  validate :references_belong_to_family

  # specific: positive per-paycheck amount (major units). percent: a fraction
  # in (0, 1]. required and leftover are derived at solve time, so a stored
  # value would be stale by definition.
  def value_matches_mode
    case mode
    when "required", "leftover"
      errors.add(:value, :blank) unless value.nil?
    when "specific"
      errors.add(:value, :numericality, greater_than: 0) unless value.present? && value > 0
    when "percent"
      errors.add(:value, :numericality, greater_than: 0, less_than_or_equal_to: 1) unless value.present? && value > 0 && value <= 1
    end
  end

  # A crafted id could pin an edge to a bill or another family's income
  # series, which the unique index alone does not catch.
  def income_series_is_income
    return if income_series_id.blank?

    errors.add(:income_series, :invalid, message: "must be a declared income series") unless
      income_series.present? && income_series.typed_income?
  end

  def references_belong_to_family
    return if family_id.blank?

    errors.add(:income_series, "must belong to the same family") if
      income_series.present? && income_series.family_id != family_id
    errors.add(:account, "must belong to the same family") if
      account.present? && account.family_id != family_id
  end
end
