# One recorded change to a loan's contract: an extra repayment, a balance the
# lender confirmed, a new instalment, or a combination. The amortisation
# schedule follows these records, so it stays the lender's own table.
#
# The record describes the contract. An extra repayment is also a transfer in
# the ledger, and a confirmed balance a balance update; those say what
# happened and are recorded separately.
#
# `term_end_date` is the day the terms that start on the effective date stop
# being fixed: the end of a fixed-rate period, or the next renewal. The
# schedule does not read it. A row can carry it alone, which is how the
# period a loan opened with is recorded.
class Loan::TermChange < ApplicationRecord
  AMOUNTS = %i[extra_repayment balance payment].freeze

  # The columns are decimal(19, 4).
  AMOUNT_LIMIT = 10**15
  AMOUNT_SCALE = 4

  # The dates a form's date input can send. A year with more digits parses
  # as a date and is more than the column can hold.
  DATE_RANGE = (Date.new(1, 1, 1)..Date.new(9999, 12, 31)).freeze

  belongs_to :loan, inverse_of: :term_changes

  validates :effective_date, presence: true
  validates :extra_repayment, numericality: { greater_than: 0, less_than: AMOUNT_LIMIT }, allow_nil: true
  validates :balance, :payment, numericality: { greater_than_or_equal_to: 0, less_than: AMOUNT_LIMIT }, allow_nil: true
  validate :records_something
  validate :changes_the_balance_once
  validate :balance_change_is_not_in_the_future
  validate :term_ends_after_it_starts

  # Whether the schedule has anything to follow in this row. One that records
  # an end date alone leaves the schedule as it is.
  def changes_schedule?
    AMOUNTS.any? { |amount| !self[amount].nil? }
  end

  # The shape Loan::Simulator takes.
  def to_schedule_change
    { date: effective_date, extra_repayment: extra_repayment, balance: balance, payment: payment }
  end

  private
    def records_something
      errors.add(:base, :records_nothing) unless changes_schedule? || term_end_date.present?
    end

    # An extra repayment lowers the balance and a confirmed balance replaces
    # it, so a row carrying both says two different things about one day.
    def changes_the_balance_once
      errors.add(:base, :two_balance_changes) if extra_repayment.present? && balance.present?
    end

    # A payment the lender has announced and the end of a period are known
    # ahead of time. A repayment or a balance is something that happened; a
    # repayment that is only planned belongs in the Extra repayments tab.
    def balance_change_is_not_in_the_future
      return unless effective_date.present? && effective_date > Date.current

      errors.add(:base, :balance_change_in_the_future) if extra_repayment.present? || balance.present?
    end

    def term_ends_after_it_starts
      return unless term_end_date.present? && effective_date.present?

      errors.add(:base, :term_ends_before_it_starts) unless term_end_date > effective_date
    end
end
