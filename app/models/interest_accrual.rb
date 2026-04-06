class InterestAccrual < ApplicationRecord
  belongs_to :depository

  validates :date, :balance_used, :daily_rate, :amount, presence: true
  validates :date, uniqueness: { scope: :depository_id }

  scope :unpaid, -> { where(paid_out: false) }
  scope :for_month, ->(year, month) {
    where(date: Date.new(year, month, 1)..Date.new(year, month, -1))
  }
  scope :for_year, ->(year) {
    where(date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
  }
end
