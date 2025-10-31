class RecurringTransaction
  class Identifier
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Identify and create/update recurring transactions for the family
    def identify_recurring_patterns
      three_months_ago = 3.months.ago.to_date

      # Get all transactions from the last 3 months
      entries_with_transactions = family.entries
        .where(entryable_type: "Transaction")
        .where("entries.date >= ?", three_months_ago)
        .includes(:entryable)
        .to_a

      # Filter to only those with merchants and group by merchant and amount (preserve sign)
      grouped_transactions = entries_with_transactions
        .select { |entry| entry.entryable.is_a?(Transaction) && entry.entryable.merchant_id.present? }
        .group_by { |entry| [ entry.entryable.merchant_id, entry.amount.round(2), entry.currency ] }

      recurring_patterns = []

      grouped_transactions.each do |(merchant_id, amount, currency), entries|
        next if entries.size < 3  # Must have at least 3 occurrences

        # Check if transactions occur on similar days (within 5 days of each other)
        days_of_month = entries.map { |e| e.date.day }.sort

        # Calculate if days cluster together (standard deviation check)
        if days_cluster_together?(days_of_month)
          expected_day = calculate_expected_day(days_of_month)
          last_occurrence = entries.max_by(&:date)

          recurring_patterns << {
            merchant_id: merchant_id,
            amount: amount,
            currency: currency,
            expected_day_of_month: expected_day,
            last_occurrence_date: last_occurrence.date,
            occurrence_count: entries.size,
            entries: entries
          }
        end
      end

      # Create or update RecurringTransaction records
      recurring_patterns.each do |pattern|
        recurring_transaction = family.recurring_transactions.find_or_initialize_by(
          merchant_id: pattern[:merchant_id],
          amount: pattern[:amount],
          currency: pattern[:currency]
        )

        recurring_transaction.assign_attributes(
          expected_day_of_month: pattern[:expected_day_of_month],
          last_occurrence_date: pattern[:last_occurrence_date],
          next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
          occurrence_count: pattern[:occurrence_count],
          status: "active"
        )

        recurring_transaction.save!
      end

      recurring_patterns.size
    end

    private
      # Check if days cluster together (within ~5 days variance)
      def days_cluster_together?(days)
        return false if days.empty?

        # Calculate standard deviation
        mean = days.sum.to_f / days.size
        variance = days.map { |day| (day - mean)**2 }.sum / days.size
        std_dev = Math.sqrt(variance)

        # Allow up to 5 days standard deviation
        std_dev <= 5
      end

      # Calculate the expected day based on the most common day
      def calculate_expected_day(days)
        # Use median as the expected day
        sorted = days.sort
        mid = sorted.size / 2

        if sorted.size.odd?
          sorted[mid]
        else
          ((sorted[mid - 1] + sorted[mid]) / 2.0).round
        end
      end

      # Calculate next expected date
      def calculate_next_expected_date(last_date, expected_day)
        next_month = last_date.next_month

        begin
          Date.new(next_month.year, next_month.month, expected_day)
        rescue ArgumentError
          # If day doesn't exist in month, use last day of month
          next_month.end_of_month
        end
      end
  end
end
