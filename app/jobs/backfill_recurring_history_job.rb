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

    # Dismissed, paused or deleted while this waited: the user has said what
    # they think of the bill, and a backfill would write payments onto it.
    return unless series&.active?

    raise FamilyLockHeld unless series.reconstruct_history!
  end
end
