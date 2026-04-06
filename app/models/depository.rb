class Depository < ApplicationRecord
  include Accountable

  has_many :interest_accruals, dependent: :destroy

  validates :interest_rate, numericality: { greater_than: 0, less_than_or_equal_to: 100 }, allow_nil: true

  SUBTYPES = {
    "checking" => { short: "Checking", long: "Checking" },
    "savings" => { short: "Savings", long: "Savings" },
    "hsa" => { short: "HSA", long: "Health Savings Account" },
    "cd" => { short: "CD", long: "Certificate of Deposit" },
    "money_market" => { short: "MM", long: "Money Market" }
  }.freeze

  class << self
    def display_name
      "Cash"
    end

    def color
      "#875BF7"
    end

    def classification
      "asset"
    end

    def icon
      "landmark"
    end
  end

  def interest_eligible?
    interest_enabled? && interest_rate.present? && interest_rate > 0
  end

  def daily_interest_rate(date = Date.current)
    return 0 unless interest_rate.present? && interest_rate > 0

    days_in_year = date.leap? ? 366 : 365
    interest_rate / 100.0 / days_in_year
  end

  def accrued_interest_this_month
    interest_accruals.for_month(Date.current.year, Date.current.month).sum(:amount)
  end

  def total_interest_this_year
    interest_accruals.for_year(Date.current.year).sum(:amount)
  end
end
