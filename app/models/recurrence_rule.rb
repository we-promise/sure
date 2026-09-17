# One repetition pattern of a recurring transaction. A series usually has one
# rule ("monthly on the 15th"); patterns that fire more than once per period are
# several rows ("semimonthly" is two monthly rules, "1st and 3rd Friday" is two
# nth-weekday rules). A series with zero rules is legal and means "legacy
# monthly on expected_day_of_month"; RecurringTransaction::Schedule synthesizes
# the implicit rule.
#
# Day anchoring is exactly one of:
#   * day_of_month (1..31, or -1 for the last day of the month)
#   * a (weekday, weekday_ordinal) pair ("3rd Friday"; ordinal -1 = last)
class RecurrenceRule < ApplicationRecord
  LAST = -1

  belongs_to :recurring_transaction

  enum :frequency, { weekly: "weekly", monthly: "monthly", yearly: "yearly" }

  validates :frequency, presence: true, inclusion: { in: frequencies.keys }
  validates :interval, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :day_of_month, numericality: { only_integer: true, in: -1..31, other_than: 0 }, allow_nil: true
  validates :weekday, numericality: { only_integer: true, in: 0..6 }, allow_nil: true
  validates :weekday_ordinal, numericality: { only_integer: true, in: -1..5, other_than: 0 }, allow_nil: true
  validates :month_of_year, numericality: { only_integer: true, in: 1..12 }, allow_nil: true
  # Position uniqueness is left to the DB index: rules are rewritten as a set,
  # so a model-level check would see the doomed rows and reject the rewrite.
  validates :position, presence: true,
                       numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :day_spec_coherent

  private
    def day_spec_coherent
      case frequency
      when "weekly"
        errors.add(:weekday, :required_for_weekly) if weekday.blank?
        errors.add(:weekday_ordinal, :not_allowed_for_weekly) if weekday_ordinal.present?
        errors.add(:day_of_month, :not_allowed_for_weekly) if day_of_month.present?
        errors.add(:month_of_year, :not_allowed) if month_of_year.present?
      when "monthly", "yearly"
        if frequency == "yearly"
          errors.add(:month_of_year, :required_for_yearly) if month_of_year.blank?
        else
          errors.add(:month_of_year, :not_allowed) if month_of_year.present?
        end

        errors.add(:base, :day_spec_required) unless day_of_month.present? ^ weekday.present?
        errors.add(:weekday_ordinal, :required_with_weekday) if weekday.present? && weekday_ordinal.blank?
        errors.add(:weekday_ordinal, :not_allowed_without_weekday) if weekday_ordinal.present? && weekday.blank?
      end
    end
end
