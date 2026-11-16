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

        # Double-check if there are any recent matching transactions
        threshold = recurring_transaction.staleness_threshold_date
        recent_matches = recurring_transaction.matching_transactions.select { |entry| entry.date >= threshold }

        if recent_matches.empty?
          recurring_transaction.mark_inactive!
          stale_count += 1
        end
      end

      stale_count
    end

    # End detected suggestions whose transactions have all since been confirmed
    # as transfer legs: they were offered while the legs were still ordinary
    # charges, and detection never revisits a suggestion it no longer finds.
    # They end as a dismissed suggestion does, because `ended` is the
    # tombstone detection leaves alone; `inactive` would list them as paused
    # bills and be deleted after six months. Confirmed bills, manual series
    # and recurring transfers (destination_account_id present, matched by
    # their pair) are never touched.
    def retire_transfer_suggestions
      retired_count = 0

      family.recurring_transactions
            .suggested
            .where(manual: false, destination_account_id: nil)
            .find_each do |recurring_transaction|
        next unless recurring_transaction.matches_only_transfer_legs?

        # Re-read under a row lock: the user may have confirmed or dismissed
        # the suggestion since this batch was loaded.
        retired = recurring_transaction.with_lock do
          recurring_transaction.suggested? && recurring_transaction.update!(status: "ended")
        end
        retired_count += 1 if retired
      end

      retired_count
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
