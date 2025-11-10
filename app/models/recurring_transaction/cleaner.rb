class RecurringTransaction
  class Cleaner
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Mark recurring transactions as inactive if they haven't occurred recently
    # Uses 2 months for automatic recurring, 6 months for manual recurring
    def cleanup_stale_transactions
      stale_count = 0

      family.recurring_transactions.active.find_each do |recurring_transaction|
        next unless recurring_transaction.should_be_inactive?

        # Determine threshold based on manual flag
        threshold = recurring_transaction.manual? ? 6.months.ago.to_date : 2.months.ago.to_date

        # Double-check if there are any recent matching transactions
        recent_matches = recurring_transaction.matching_transactions.select { |entry| entry.date >= threshold }

        if recent_matches.empty?
          recurring_transaction.mark_inactive!
          stale_count += 1
        end
      end

      stale_count
    end

    # Remove inactive recurring transactions that have been inactive for 6+ months
    # Manual recurring transactions are never automatically deleted
    def remove_old_inactive_transactions
      six_months_ago = 6.months.ago

      family.recurring_transactions
        .inactive
        .where(manual: false)
        .where("updated_at < ?", six_months_ago)
        .destroy_all
    end
  end
end
