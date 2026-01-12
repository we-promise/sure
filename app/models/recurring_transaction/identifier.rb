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

      # Group by merchant (if present) or name, along with amount (preserve sign) and currency
      grouped_transactions = entries_with_transactions
        .select { |entry| entry.entryable.is_a?(Transaction) }
        .group_by do |entry|
          transaction = entry.entryable
          # Use merchant_id if present, otherwise use entry name
          identifier = transaction.merchant_id.present? ? [ :merchant, transaction.merchant_id ] : [ :name, entry.name ]
          [ identifier, entry.amount.round(2), entry.currency ]
        end

      recurring_patterns = []

      grouped_transactions.each do |(identifier, amount, currency), entries|
        next if entries.size < 3  # Must have at least 3 occurrences

        # Check if the last occurrence was within the last 45 days
        last_occurrence = entries.max_by(&:date)
        next if last_occurrence.date < 45.days.ago.to_date

        # Check if transactions occur on similar days (within 5 days of each other)
        days_of_month = entries.map { |e| e.date.day }.sort

        # Calculate if days cluster together (standard deviation check)
        if days_cluster_together?(days_of_month)
          expected_day = calculate_expected_day(days_of_month)

          # Unpack identifier - either [:merchant, id] or [:name, name_string]
          identifier_type, identifier_value = identifier

          pattern = {
            amount: amount,
            currency: currency,
            expected_day_of_month: expected_day,
            last_occurrence_date: last_occurrence.date,
            occurrence_count: entries.size,
            entries: entries
          }

          if identifier_type == :merchant
            pattern[:merchant_id] = identifier_value
          else
            pattern[:name] = identifier_value
          end

          recurring_patterns << pattern
        end
      end

      # Create or update RecurringTransaction records
      recurring_patterns.each do |pattern|
        # Build find conditions based on whether it's merchant-based or name-based
        find_conditions = {
          amount: pattern[:amount],
          currency: pattern[:currency]
        }

        if pattern[:merchant_id].present?
          find_conditions[:merchant_id] = pattern[:merchant_id]
          find_conditions[:name] = nil
        else
          find_conditions[:name] = pattern[:name]
          find_conditions[:merchant_id] = nil
        end

        begin
          recurring_transaction = family.recurring_transactions.find_or_initialize_by(find_conditions)

          # Handle manual recurring transactions specially
          if recurring_transaction.persisted? && recurring_transaction.manual?
            # Update variance for manual recurring transactions
            update_manual_recurring_variance(recurring_transaction, pattern)
            next
          end

          # Set the name or merchant_id on new records
          if recurring_transaction.new_record?
            if pattern[:merchant_id].present?
              recurring_transaction.merchant_id = pattern[:merchant_id]
            else
              recurring_transaction.name = pattern[:name]
            end
            # New auto-detected recurring transactions are not manual
            recurring_transaction.manual = false
          end

          recurring_transaction.assign_attributes(
            expected_day_of_month: pattern[:expected_day_of_month],
            last_occurrence_date: pattern[:last_occurrence_date],
            next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
            occurrence_count: pattern[:occurrence_count],
            status: recurring_transaction.new_record? ? "active" : recurring_transaction.status
          )

          recurring_transaction.save!
        rescue ActiveRecord::RecordNotUnique
          # Race condition: another process created the same record between find and save.
          # Retry with find to get the existing record and update it.
          recurring_transaction = family.recurring_transactions.find_by(find_conditions)
          next unless recurring_transaction

          # Skip manual recurring transactions
          if recurring_transaction.manual?
            update_manual_recurring_variance(recurring_transaction, pattern)
            next
          end

          recurring_transaction.update!(
            expected_day_of_month: pattern[:expected_day_of_month],
            last_occurrence_date: pattern[:last_occurrence_date],
            next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
            occurrence_count: pattern[:occurrence_count]
          )
        end
      end

      # Also check for manual recurring transactions that might need variance updates
      update_manual_recurring_transactions(three_months_ago)

      recurring_patterns.size
    end

    # Update variance for existing manual recurring transactions
    def update_manual_recurring_transactions(since_date)
      family.recurring_transactions.where(manual: true, status: "active").find_each do |recurring|
        # Find matching transactions in the recent period
        matching_entries = RecurringTransaction.find_matching_transaction_entries(
          family: family,
          merchant_id: recurring.merchant_id,
          name: recurring.name,
          currency: recurring.currency,
          expected_day: recurring.expected_day_of_month,
          lookback_months: 6
        )

        next if matching_entries.empty?

        # Extract amounts and dates from all matching entries
        matching_amounts = matching_entries.map(&:amount)
        last_entry = matching_entries.max_by(&:date)

        # Recalculate variance from all occurrences (including identical amounts)
        recurring.update!(
          expected_amount_min: matching_amounts.min,
          expected_amount_max: matching_amounts.max,
          expected_amount_avg: matching_amounts.sum / matching_amounts.size,
          occurrence_count: matching_amounts.size,
          last_occurrence_date: last_entry.date,
          next_expected_date: calculate_next_expected_date(last_entry.date, recurring.expected_day_of_month)
        )
      end
    end

    # Update variance for a manual recurring transaction when pattern is found
    def update_manual_recurring_variance(recurring_transaction, pattern)
      # Check if this transaction's date is more recent
      if pattern[:last_occurrence_date] > recurring_transaction.last_occurrence_date
        # Find all matching transactions to recalculate variance
        matching_entries = RecurringTransaction.find_matching_transaction_entries(
          family: family,
          merchant_id: recurring_transaction.merchant_id,
          name: recurring_transaction.name,
          currency: recurring_transaction.currency,
          expected_day: recurring_transaction.expected_day_of_month,
          lookback_months: 6
        )

        # Update if we have any matching transactions
        if matching_entries.any?
          matching_amounts = matching_entries.map(&:amount)

          recurring_transaction.update!(
            expected_amount_min: matching_amounts.min,
            expected_amount_max: matching_amounts.max,
            expected_amount_avg: matching_amounts.sum / matching_amounts.size,
            occurrence_count: matching_amounts.size,
            last_occurrence_date: pattern[:last_occurrence_date],
            next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], recurring_transaction.expected_day_of_month)
          )
        end
      end
    end

    private
      # Check if days cluster together (within ~5 days variance)
      # Uses circular distance to handle month-boundary wrapping (e.g., 28, 29, 30, 31, 1, 2)
      def days_cluster_together?(days)
        return false if days.empty?

        # Calculate median as reference point
        median = calculate_expected_day(days)

        # Calculate circular distances from median
        circular_distances = days.map { |day| circular_distance(day, median) }

        # Calculate standard deviation of circular distances
        mean_distance = circular_distances.sum.to_f / circular_distances.size
        variance = circular_distances.map { |dist| (dist - mean_distance)**2 }.sum / circular_distances.size
        std_dev = Math.sqrt(variance)

        # Allow up to 5 days standard deviation
        std_dev <= 5
      end

      # Calculate circular distance between two days on a 31-day circle
      # Examples:
      #   circular_distance(1, 31) = 2  (wraps around: 31 -> 1 is 1 day forward)
      #   circular_distance(28, 2) = 5  (wraps: 28, 29, 30, 31, 1, 2)
      def circular_distance(day1, day2)
        linear_distance = (day1 - day2).abs
        wrap_distance = 31 - linear_distance
        [ linear_distance, wrap_distance ].min
      end

      # Calculate the expected day based on the most common day
      # Uses circular rotation to handle month-wrapping sequences (e.g., [29, 30, 31, 1, 2])
      def calculate_expected_day(days)
        return days.first if days.size == 1

        # Convert to 0-indexed (0-30 instead of 1-31) for modular arithmetic
        days_0 = days.map { |d| d - 1 }

        # Find the rotation (pivot) that minimizes span, making the cluster contiguous
        # This handles month-wrapping sequences like [29, 30, 31, 1, 2]
        best_pivot = 0
        min_span = Float::INFINITY

        (0..30).each do |pivot|
          rotated = days_0.map { |d| (d - pivot) % 31 }
          span = rotated.max - rotated.min

          if span < min_span
            min_span = span
            best_pivot = pivot
          end
        end

        # Rotate days using best pivot to create contiguous array
        rotated_days = days_0.map { |d| (d - best_pivot) % 31 }.sort

        # Calculate median on rotated, contiguous array
        mid = rotated_days.size / 2
        rotated_median = if rotated_days.size.odd?
          rotated_days[mid]
        else
          # For even count, average and round
          ((rotated_days[mid - 1] + rotated_days[mid]) / 2.0).round
        end

        # Map median back to original day space (unrotate) and convert to 1-indexed
        original_day = (rotated_median + best_pivot) % 31 + 1

        original_day
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
