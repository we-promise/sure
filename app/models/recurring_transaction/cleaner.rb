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
        recent_matches = unclaimed_by_other_series(recurring_transaction, recent_matches) if recurring_transaction.transfer?

        if recent_matches.empty?
          recurring_transaction.mark_inactive!
          stale_count += 1
        end
      end

      stale_count
    end

    # Delete detected suggestions whose transactions have all since been
    # confirmed as transfer legs: they were offered while the legs were still
    # ordinary charges, and detection never revisits a suggestion it no longer
    # finds. Deleting rather than tombstoning as `ended` keeps them revivable:
    # nothing rebuilds the row while the transfers stand, and if the transfers
    # are later unlinked the legs are ordinary again and detection offers the
    # bill afresh. An `ended` row would block that, as it does for a user's
    # dismissal. Confirmed bills, manual series and recurring transfers
    # (destination_account_id present, matched by their pair) are never
    # touched, nor is any series in `claimed_ids`: the ones detection just
    # attributed this run's ordinary charges to, which may sit at an amount
    # `matching_transactions` does not look at.
    def retire_transfer_suggestions(claimed_ids: [])
      retired_count = 0

      retirement_candidates(claimed_ids).find_each do |recurring_transaction|
        next unless recurring_transaction.matches_only_transfer_legs?

        # Re-check under a row lock: the user may have confirmed or dismissed
        # the suggestion, an import may have marked it manual, or one of its
        # transfers may have been unlinked since the check.
        retired = recurring_transaction.with_lock do
          recurring_transaction.suggested? &&
            !recurring_transaction.manual? &&
            recurring_transaction.matches_only_transfer_legs? &&
            recurring_transaction.destroy!
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

    private

      def retirement_candidates(claimed_ids)
        family.recurring_transactions
              .suggested
              .where(manual: false, destination_account_id: nil)
              .where.not(id: claimed_ids)
      end

      # Same-amount transfer series between the same accounts sit within each
      # other's posting tolerance, so one transfer can fit several. Once the
      # Matcher has confirmed it as another series' payment it is not evidence
      # that this one is still running.
      def unclaimed_by_other_series(series, entries)
        return entries if entries.empty?

        claimed_entry_ids = RecurringAllocation.confirmed
          .joins(:recurring_occurrence)
          .where(entry_id: entries.map(&:id))
          .where.not(recurring_occurrences: { recurring_transaction_id: series.id })
          .pluck(:entry_id)

        entries.reject { |entry| claimed_entry_ids.include?(entry.id) }
      end
  end
end
