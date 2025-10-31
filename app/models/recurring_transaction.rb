class RecurringTransaction < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :merchant

  monetize :amount

  enum :status, { active: "active", inactive: "inactive" }

  validates :amount, presence: true
  validates :currency, presence: true
  validates :expected_day_of_month, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 31 }

  scope :for_family, ->(family) { where(family: family) }
  scope :expected_soon, -> { active.where("next_expected_date <= ?", 1.month.from_now) }

  # Class methods for identification and cleanup
  def self.identify_patterns_for(family)
    Identifier.new(family).identify_recurring_patterns
  end

  def self.cleanup_stale_for(family)
    Cleaner.new(family).cleanup_stale_transactions
  end

  # Find matching transactions for this recurring pattern
  def matching_transactions
    entries = family.entries
      .where(entryable_type: "Transaction")
      .where(currency: currency)
      .where("entries.amount = ?", amount)
      .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
             [ expected_day_of_month - 2, 1 ].max,
             [ expected_day_of_month + 2, 31 ].min)
      .order(date: :desc)

    # Filter by merchant through the entryable (Transaction)
    entries.select do |entry|
      entry.entryable.is_a?(Transaction) && entry.entryable.merchant_id == merchant_id
    end
  end

  # Check if this recurring transaction should be marked inactive
  def should_be_inactive?
    return false if last_occurrence_date.nil?
    last_occurrence_date < 2.months.ago
  end

  # Mark as inactive
  def mark_inactive!
    update!(status: "inactive")
  end

  # Mark as active
  def mark_active!
    update!(status: "active")
  end

  # Update based on a new transaction occurrence
  def record_occurrence!(transaction_date)
    self.last_occurrence_date = transaction_date
    self.next_expected_date = calculate_next_expected_date(transaction_date)
    self.occurrence_count += 1
    self.status = "active"
    save!
  end

  # Calculate the next expected date based on the last occurrence
  def calculate_next_expected_date(from_date = last_occurrence_date)
    # Start with next month
    next_month = from_date.next_month

    # Try to use the expected day of month
    begin
      Date.new(next_month.year, next_month.month, expected_day_of_month)
    rescue ArgumentError
      # If day doesn't exist in month (e.g., 31st in February), use last day of month
      next_month.end_of_month
    end
  end

  # Get the projected transaction for display
  def projected_entry
    return nil unless active?
    return nil unless next_expected_date.future?

    OpenStruct.new(
      date: next_expected_date,
      amount: amount,
      currency: currency,
      merchant: merchant,
      recurring: true,
      projected: true
    )
  end

  private
    def monetizable_currency
      currency
    end
end
