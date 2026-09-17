# Bills subsystem: after detecting patterns this now runs the rest of the
# pipeline -- materialize occurrences, repair provider-replaced entries, match.
class IdentifyRecurringTransactionsJob < ApplicationJob
  queue_as :default

  # Debounce: if called multiple times within the delay window,
  # only the last scheduled job will actually run
  DEBOUNCE_DELAY = 30.seconds

  def perform(family_id, scheduled_at)
    family = Family.find_by(id: family_id)
    return unless family
    return if family.recurring_transactions_disabled?

    # Check if this job is stale (a newer one was scheduled)
    latest_scheduled = Rails.cache.read(cache_key(family_id))
    return if latest_scheduled && latest_scheduled > scheduled_at

    # Check if there are still incomplete syncs - if so, skip and let the last sync trigger it
    return if family_has_incomplete_syncs?(family)

    # Use advisory lock as final safety net against concurrent execution
    RecurringTransaction::Pipeline.with_family_lock(family_id) do
      RecurringTransaction::Pipeline.new(family).run!
    end
  end

  def self.schedule_for(family)
    return if family.recurring_transactions_disabled?

    scheduled_at = Time.current.to_f
    cache_key = "recurring_transaction_identify:#{family.id}"

    # Store the latest scheduled time
    Rails.cache.write(cache_key, scheduled_at, expires_in: DEBOUNCE_DELAY + 10.seconds)

    # Schedule the job with delay
    set(wait: DEBOUNCE_DELAY).perform_later(family.id, scheduled_at)
  end

  private

    def cache_key(family_id)
      "recurring_transaction_identify:#{family_id}"
    end

    # Debounce gate: delegate to `Sync.any_incomplete_for?`, which polls every
    # `Syncable` provider association on `Family` via reflection. The previous
    # hand-rolled list covered only 5 of the 14 `*_items` associations on
    # `Family`, so a Coinbase/Mercury/Brex/etc. sync in flight silently
    # bypassed this gate and let the identifier run against a partial dataset.
    def family_has_incomplete_syncs?(family)
      Sync.any_incomplete_for?(family)
    end
end
