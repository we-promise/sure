# Stores individual payment records for an amortization schedule
class LoanAmortization < ApplicationRecord
  belongs_to :loan

  validates :payment_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_amount, :principal_payment, :interest_payment, :beginning_balance, :ending_balance, :interest_rate, :schedule_signature, :algorithm_version, :generated_at, presence: true

  # Order payments by payment number
  scope :ordered, -> { order(payment_number: :asc) }
end
