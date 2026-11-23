# Reconstructs one bill's past payments when activating it could not: the
# activation found a pipeline holding the family lock. Skipping instead left
# the bill with no history for good, because the live matcher only ever looks
# at open occurrences from the current cycle on.
class BackfillRecurringHistoryJob < ApplicationJob
  queue_as :default

  class FamilyLockHeld < StandardError; end

  retry_on FamilyLockHeld, wait: :polynomially_longer, attempts: 10

  def perform(series_id)
    series = RecurringTransaction.find_by(id: series_id)
    return unless series

    # Dismissed, paused or deleted while this waited: a backfill would write
    # payments onto it. Clearing or moving its start date still has to remove
    # generated open history, so that part runs without touching payments.
    unless series.active?
      acquired = RecurringTransaction::Pipeline.with_family_lock(series.family_id) do
        series.trim_unallocated_history_before_started_on!
      end
      raise FamilyLockHeld unless acquired

      return
    end

    raise FamilyLockHeld unless series.reconstruct_history!
  end
end
