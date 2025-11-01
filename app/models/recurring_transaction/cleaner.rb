class RecurringTransaction
  class Cleaner
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Mark recurring transactions as inactive if they haven't occurred in 2+ months
    def cleanup_stale_transactions
      two_months_ago = 2.months.ago.to_date

      stale_transactions = family.recurring_transactions
        .active
        .where("last_occurrence_date < ?", two_months_ago)

      stale_count = 0
      stale_transactions.find_each do |recurring_transaction|
        # Double-check if there are any recent matching transactions
        recent_matches = recurring_transaction.matching_transactions.select { |entry| entry.date >= two_months_ago }

        if recent_matches.empty?
          recurring_transaction.mark_inactive!
          stale_count += 1
        end
      end

      stale_count
    end

    # Remove inactive recurring transactions that have been inactive for 6+ months
    def remove_old_inactive_transactions
      six_months_ago = 6.months.ago

      family.recurring_transactions
        .inactive
        .where("updated_at < ?", six_months_ago)
        .destroy_all
    end
  end
end
