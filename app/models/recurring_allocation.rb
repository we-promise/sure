# One payment (or part of one) applied to one occurrence. Several allocations
# sum toward a single obligation -- that is the whole partial-payment model --
# and one entry may be split across several occurrences, each allocation
# carrying its own amount.
#
# entry_id is nullable by design: a payment recorded by hand (cash, or a bank
# feed that has not caught up) is a real payment with no entry. If an entry is
# later deleted, the FK nullifies rather than cascades, so the payment record
# and its amount survive.
class RecurringAllocation < ApplicationRecord
  include Monetizable

  belongs_to :recurring_occurrence
  belongs_to :entry, optional: true

  monetize :allocated_amount

  enum :state, { suggested: "suggested", confirmed: "confirmed" }, prefix: :allocation
  enum :source, { auto_matched: "auto_matched", user_confirmed: "user_confirmed",
                  user_created: "user_created" }, prefix: :from

  validates :allocated_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validate :currency_matches_occurrence

  scope :confirmed, -> { where(state: :confirmed) }
  scope :suggested, -> { where(state: :suggested) }

  before_validation :default_paid_on

  private
    def currency_matches_occurrence
      return if recurring_occurrence.nil? || currency == recurring_occurrence.currency

      errors.add(:currency, :must_match_occurrence)
    end

    def default_paid_on
      self.paid_on ||= entry&.date || Date.current
    end
end
