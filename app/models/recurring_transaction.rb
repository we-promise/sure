class RecurringTransaction < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :merchant, optional: true

  monetize :amount
  monetize :expected_amount_min, allow_nil: true
  monetize :expected_amount_max, allow_nil: true
  monetize :expected_amount_avg, allow_nil: true

  enum :status, { active: "active", inactive: "inactive" }

  validates :amount, presence: true
  validates :currency, presence: true
  validates :expected_day_of_month, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 31 }
  validate :merchant_or_name_present
  validate :amount_variance_consistency

  def merchant_or_name_present
    if merchant_id.blank? && name.blank?
      errors.add(:base, "Either merchant or name must be present")
    end
  end

  def amount_variance_consistency
    return unless manual?

    if expected_amount_min.present? && expected_amount_max.present?
      if expected_amount_min > expected_amount_max
        errors.add(:expected_amount_min, "cannot be greater than expected_amount_max")
      end
    end
  end

  scope :for_family, ->(family) { where(family: family) }
  scope :expected_soon, -> { active.where("next_expected_date <= ?", 1.month.from_now) }

  # Class methods for identification and cleanup
  # Schedules pattern identification with debounce to run after all syncs complete
  def self.identify_patterns_for(family)
    IdentifyRecurringTransactionsJob.schedule_for(family)
    0 # Return immediately, actual count will be determined by the job
  end

  # Synchronous pattern identification (for manual triggers from UI)
  def self.identify_patterns_for!(family)
    Identifier.new(family).identify_recurring_patterns
  end

  def self.cleanup_stale_for(family)
    Cleaner.new(family).cleanup_stale_transactions
  end

  # Create a manual recurring transaction from an existing transaction
  # Automatically calculates amount variance from past 6 months of matching transactions
  def self.create_from_transaction(transaction, date_variance: 2)
    entry = transaction.entry
    family = entry.account.family
    expected_day = entry.date.day

    # Find matching transactions from the past 6 months
    matching_amounts = find_matching_transaction_amounts(
      family: family,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      currency: entry.currency,
      expected_day: expected_day,
      lookback_months: 6
    )

    # Calculate amount variance from historical data
    expected_min = expected_max = expected_avg = nil
    if matching_amounts.size > 1
      # Multiple transactions found - calculate variance
      expected_min = matching_amounts.min
      expected_max = matching_amounts.max
      expected_avg = matching_amounts.sum / matching_amounts.size
    elsif matching_amounts.size == 1
      # Single transaction - no variance yet
      amount = matching_amounts.first
      expected_min = amount
      expected_max = amount
      expected_avg = amount
    end

    # Calculate next expected date relative to today, not the transaction date
    next_expected = calculate_next_expected_date_from_today(expected_day)

    create!(
      family: family,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: expected_day,
      last_occurrence_date: entry.date,
      next_expected_date: next_expected,
      status: "active",
      occurrence_count: matching_amounts.size,
      manual: true,
      expected_amount_min: expected_min,
      expected_amount_max: expected_max,
      expected_amount_avg: expected_avg
    )
  end

  # Find matching transaction entries for variance calculation
  def self.find_matching_transaction_entries(family:, merchant_id:, name:, currency:, expected_day:, lookback_months: 6)
    lookback_date = lookback_months.months.ago.to_date

    entries = family.entries
      .where(entryable_type: "Transaction")
      .where(currency: currency)
      .where("entries.date >= ?", lookback_date)
      .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
             [ expected_day - 2, 1 ].max,
             [ expected_day + 2, 31 ].min)
      .order(date: :desc)

    # Filter by merchant or name
    if merchant_id.present?
      # Join with transactions table to filter by merchant_id in SQL (avoids N+1)
      entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(transactions: { merchant_id: merchant_id })
        .to_a
    else
      entries.where(name: name).to_a
    end
  end

  # Find matching transaction amounts for variance calculation
  def self.find_matching_transaction_amounts(family:, merchant_id:, name:, currency:, expected_day:, lookback_months: 6)
    matching_entries = find_matching_transaction_entries(
      family: family,
      merchant_id: merchant_id,
      name: name,
      currency: currency,
      expected_day: expected_day,
      lookback_months: lookback_months
    )

    matching_entries.map(&:amount)
  end

  # Calculate next expected date from today
  def self.calculate_next_expected_date_from_today(expected_day)
    today = Date.current

    # Try this month first
    begin
      this_month_date = Date.new(today.year, today.month, expected_day)
      return this_month_date if this_month_date > today
    rescue ArgumentError
      # Day doesn't exist in this month (e.g., 31st in February)
    end

    # Otherwise use next month
    calculate_next_expected_date_for(today, expected_day)
  end

  def self.calculate_next_expected_date_for(from_date, expected_day)
    next_month = from_date.next_month
    begin
      Date.new(next_month.year, next_month.month, expected_day)
    rescue ArgumentError
      next_month.end_of_month
    end
  end

  # Find matching transactions for this recurring pattern
  def matching_transactions
    # For manual recurring with amount variance, match within range
    # For automatic recurring, match exact amount
    entries = if manual? && has_amount_variance?
      family.entries
        .where(entryable_type: "Transaction")
        .where(currency: currency)
        .where("entries.amount BETWEEN ? AND ?", expected_amount_min, expected_amount_max)
        .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
               [ expected_day_of_month - 2, 1 ].max,
               [ expected_day_of_month + 2, 31 ].min)
        .order(date: :desc)
    else
      family.entries
        .where(entryable_type: "Transaction")
        .where(currency: currency)
        .where("entries.amount = ?", amount)
        .where("EXTRACT(DAY FROM entries.date) BETWEEN ? AND ?",
               [ expected_day_of_month - 2, 1 ].max,
               [ expected_day_of_month + 2, 31 ].min)
        .order(date: :desc)
    end

    # Filter by merchant or name
    if merchant_id.present?
      # Match by merchant through the entryable (Transaction)
      entries.select do |entry|
        entry.entryable.is_a?(Transaction) && entry.entryable.merchant_id == merchant_id
      end
    else
      # Match by entry name
      entries.where(name: name)
    end
  end

  # Check if this recurring transaction has amount variance configured
  def has_amount_variance?
    expected_amount_min.present? && expected_amount_max.present?
  end

  # Check if this recurring transaction should be marked inactive
  def should_be_inactive?
    return false if last_occurrence_date.nil?
    # Manual recurring transactions have a longer threshold
    threshold = manual? ? 6.months.ago : 2.months.ago
    last_occurrence_date < threshold
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
  def record_occurrence!(transaction_date, transaction_amount = nil)
    self.last_occurrence_date = transaction_date
    self.next_expected_date = calculate_next_expected_date(transaction_date)

    # Update amount variance for manual recurring transactions BEFORE incrementing count
    if manual? && transaction_amount.present?
      update_amount_variance(transaction_amount)
    end

    self.occurrence_count += 1
    self.status = "active"
    save!
  end

  # Update amount variance tracking based on a new transaction
  def update_amount_variance(transaction_amount)
    # First sample - initialize everything
    if expected_amount_avg.nil?
      self.expected_amount_min = transaction_amount
      self.expected_amount_max = transaction_amount
      self.expected_amount_avg = transaction_amount
      return
    end

    # Update min/max
    self.expected_amount_min = [ expected_amount_min, transaction_amount ].min if expected_amount_min.present?
    self.expected_amount_max = [ expected_amount_max, transaction_amount ].max if expected_amount_max.present?

    # Calculate new average using incremental formula
    # For n samples with average A_n, adding sample x_{n+1} gives:
    # A_{n+1} = A_n + (x_{n+1} - A_n)/(n+1)
    # occurrence_count includes the initial occurrence, so subtract 1 to get variance samples recorded
    n = occurrence_count - 1  # Number of variance samples recorded so far
    self.expected_amount_avg = expected_amount_avg + ((transaction_amount - expected_amount_avg) / (n + 1))
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

    # Use average amount for manual recurring with variance, otherwise use fixed amount
    display_amount = if manual? && expected_amount_avg.present?
      expected_amount_avg
    else
      amount
    end

    OpenStruct.new(
      date: next_expected_date,
      amount: display_amount,
      currency: currency,
      merchant: merchant,
      name: merchant.present? ? merchant.name : name,
      recurring: true,
      projected: true,
      amount_min: expected_amount_min,
      amount_max: expected_amount_max,
      amount_avg: expected_amount_avg,
      has_variance: has_amount_variance?
    )
  end

  private
    def monetizable_currency
      currency
    end
end
