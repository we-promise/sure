class RecurringTransaction
  # Bills subsystem: staleness is measured in the series' own cycles, so
  # quarterly and annual bills survive the gaps between normal occurrences.
  class Cleaner
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Mark recurring transactions as inactive if they haven't occurred
    # recently, where "recently" is measured in the series' own cycles (see
    # RecurringTransaction#staleness_threshold_date) so quarterly and annual
    # bills survive the gaps between their perfectly normal occurrences.
    #
    # Transfer rows (destination_account_id present) are included: as of issue
    # #1590, `matching_transactions` detects the Transfer pair, so a still-active
    # transfer keeps surfacing recent matches and stays active, while one whose
    # pair has genuinely stopped is correctly retired.
    def cleanup_stale_transactions
      stale_count = 0

      family.recurring_transactions
            .active
            .find_each do |recurring_transaction|
        next unless recurring_transaction.should_be_inactive?

        # A financed plan with installments still due is not stale.
        if recurring_transaction.financed? &&
           recurring_transaction.recurring_occurrences
             .where(status: "scheduled")
             .where("due_on >= ?", Date.current)
             .exists?
          next
        end

        # Double-check if there are any recent matching transactions
        threshold = recurring_transaction.staleness_threshold_date
        recent_matches = recurring_transaction.matching_transactions.select { |entry| entry.date >= threshold }

        if recent_matches.empty?
          if recurring_transaction.financed?
            # A plan with any allocation, including a suggestion that can still
            # be confirmed, stays locked to its purchase. Only a plan with no
            # allocation at all may release the purchase.
            if recurring_transaction.financed_allocations_present?
              recurring_transaction.mark_inactive!
            else
              recurring_transaction.update!(status: "ended")
            end
          else
            recurring_transaction.mark_inactive!
          end
          stale_count += 1
        end
      end

      stale_count
    end

    # Remove inactive recurring transactions that have been inactive for 6+ months
    # Manual recurring transactions are never automatically deleted
    def remove_old_inactive_transactions
      six_months_ago = 6.months.ago

      # Financed plans are manual series, so `manual: false` already keeps them
      # here; an allocated plan's destroy is further blocked by the
      # before_destroy callback.
      family.recurring_transactions
        .inactive
        .where(manual: false)
        .where("updated_at < ?", six_months_ago)
        .destroy_all
    end
  end
end
