# One recorded change to a loan's contract: an extra repayment, a balance the
# lender confirmed, a new instalment, or a combination. The amortisation
# schedule follows these records, so it stays the lender's own table.
#
# The record describes the contract. An extra repayment is also a transfer in
# the ledger, and a confirmed balance a balance update; those say what
# happened and are recorded separately.
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
  validate :changes_something
  validate :changes_the_balance_once
  validate :effective_date_is_not_in_the_future

  # The shape Loan::Simulator takes.
  def to_schedule_change
    { date: effective_date, extra_repayment: extra_repayment, balance: balance, payment: payment }
  end

  private
    def changes_something
      errors.add(:base, :no_amount) if AMOUNTS.all? { |amount| self[amount].nil? }
    end

    # An extra repayment lowers the balance and a confirmed balance replaces
    # it, so a row carrying both says two different things about one day.
    def changes_the_balance_once
      errors.add(:base, :two_balance_changes) if extra_repayment.present? && balance.present?
    end

    # A change is something that happened. A repayment that is only planned
    # belongs in the Extra repayments tab.
    def effective_date_is_not_in_the_future
      errors.add(:base, :in_the_future) if effective_date.present? && effective_date > Date.current
    end
end
