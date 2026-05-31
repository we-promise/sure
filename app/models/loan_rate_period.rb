class LoanRatePeriod < ApplicationRecord
  belongs_to :loan

  validates :starts_on, presence: true
  validates :annual_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :payment_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :starts_on, uniqueness: { scope: :loan_id }, if: -> { loan_id.present? && starts_on.present? }
end
