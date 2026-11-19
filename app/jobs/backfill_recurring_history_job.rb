# Reconstructs one bill's past payments when activating or declaring it could
# not: the callback found a pipeline holding the family lock. Skipping instead left
# the bill with no history for good, because the live matcher only ever looks
# at open occurrences from the current cycle on.
class BackfillRecurringHistoryJob < ApplicationJob
  queue_as :default

  class FamilyLockHeld < StandardError; end

  retry_on FamilyLockHeld, wait: :polynomially_longer, attempts: 10

  # as_of is the day the bill was activated or declared, and declared says
  # which. Jobs queued before they were passed run for today, as activations.
  def perform(series_id, as_of = nil, declared = false)
    series = RecurringTransaction.find_by(id: series_id)

    # Dismissed, paused or deleted while this waited: the user has said what
    # they think of the bill, and a backfill would write payments onto it.
    return unless series&.active?

    raise FamilyLockHeld unless series.reconstruct_history!(as_of: as_of || Date.current, declared: declared)
  end
end
