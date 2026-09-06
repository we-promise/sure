# Replays a Plaid item's full transaction history so a naming-preference change
# reaches transactions that already exist.
#
# The cursor reset cannot happen inline with the preference change. If a sync is
# already in flight it read the old cursor before we touched anything and writes
# its own cursor back when it finishes (PlaidItem::Importer), erasing the reset;
# Syncable#sync_later would also coalesce into that active sync and enqueue no
# job at all. Since re-saving the same preference is a no-op, the replay would
# then never happen. So we wait for a quiet moment, then reset and sync.
class PlaidHistoryReplayJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 30

  # Clears the item's cursor and queues a sync, retrying while another sync
  # holds the item. Gives up after MAX_ATTEMPTS and records the abandonment for
  # support rather than leaving the caller believing history was replayed.
  #
  # @param plaid_item [PlaidItem] the connection whose history should be replayed
  # @param attempts_remaining [Integer] retries left before giving up
  # @return [void]
  def perform(plaid_item, attempts_remaining: MAX_ATTEMPTS)
    # Checking, resetting and queueing under one row lock. Done separately, a
    # sync could be created after the check, read the old cursor, absorb this
    # request through sync_later's coalescing, and then write its cursor back
    # over the reset — leaving history unreplayed with nothing queued to retry.
    # Holding the lock across all three means a competing sync_later either
    # lands before the check (so we defer) or after the reset (so it coalesces
    # into the replay sync, which already starts from a nil cursor).
    replayed = plaid_item.with_lock do
      if plaid_item.syncs.incomplete.exists?
        false
      else
        plaid_item.update!(next_cursor: nil)
        plaid_item.sync_later
        true
      end
    end

    return if replayed

    if attempts_remaining.positive?
      self.class.set(wait: RETRY_DELAY).perform_later(
        plaid_item,
        attempts_remaining: attempts_remaining - 1
      )
    else
      DebugLogEntry.capture(
        category: "background_jobs",
        level: "warn",
        message: "Gave up waiting to replay PlaidItem #{plaid_item.id} history; transactions keep their previous naming",
        source: self.class.name,
        family: plaid_item.family,
        provider_key: "plaid",
        metadata: { plaid_item_id: plaid_item.id }
      )
    end
  end
end
