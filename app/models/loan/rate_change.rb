# An effective-dated interest-rate override for a loan. The base
# `loans.interest_rate` is the rate in effect from origination; each RateChange
# resets it from `effective_date` forward, letting the accrual engine price a
# variable/adjustable-rate loan against the rate the lender actually charged in
# each period rather than repricing the whole history whenever the rate moves.
class Loan::RateChange < ApplicationRecord
  self.table_name = "loan_rate_changes"

  belongs_to :loan, inverse_of: :rate_changes

  validates :effective_date, presence: true
  validates :effective_date, uniqueness: { scope: :loan_id }
  validates :rate, presence: true,
                   numericality: { greater_than_or_equal_to: 0 }

  # A rate change moves the derived balance just like editing the base rate does,
  # but it is a child row so it never touches the loan's own `saved_changes` —
  # Loan#resync_account_for_accrual_changes would not fire. Trigger the resync
  # here instead, mirroring that path.
  after_save_commit :resync_loan_account
  after_destroy_commit :resync_loan_account

  private
    def resync_loan_account
      loan.resync_for_accrual!
    end
end
