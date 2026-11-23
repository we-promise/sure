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
  validate :entry_is_not_refund

  # A confirmed allocation on a refund is no longer a payment, even if a row
  # survives a classification that raced with allocation creation. Exclude
  # those rows from every paid total; unallocate_entry! reads the raw state to
  # remove them.
  scope :confirmed, -> {
    where(state: :confirmed).where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1
        FROM entries AS refund_entries
        INNER JOIN transactions AS refund_transactions
          ON refund_transactions.id = refund_entries.entryable_id
         AND refund_entries.entryable_type = 'Transaction'
        WHERE refund_entries.id = recurring_allocations.entry_id
          AND refund_transactions.kind = 'refund'
      )
    SQL
  }
  scope :suggested, -> { where(state: :suggested) }

  before_validation :default_paid_on

  # Confirmed payments of the family's bills. Transfers to liabilities are
  # not spending and stay out, as do tombstones of ended series (a deleted or
  # dismissed bill), which the Allocator also ignores so the entry can be
  # matched again.
  scope :to_family_bills, ->(family) {
    confirmed
      .joins(recurring_occurrence: :recurring_transaction)
      .merge(RecurringTransaction.outflows)
      .where(recurring_transactions: { family_id: family.id })
      .where.not(recurring_transactions: { status: "ended" })
  }

  private
    def entry_is_not_refund
      return unless entry&.transaction?
      return unless Transaction.where(id: entry.entryable_id, kind: "refund").exists?

      errors.add(:entry, :refund_not_allowed)
    end

    def currency_matches_occurrence
      return if recurring_occurrence.nil? || currency == recurring_occurrence.currency

      errors.add(:currency, :must_match_occurrence)
    end

    def default_paid_on
      self.paid_on ||= entry&.date || Date.current
    end
end
