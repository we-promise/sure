# Asynchronous deletion for provider connections (the `*_item` models).
#
# `destroy_later` flags the row and enqueues DestroyJob. A flagged row drops out
# of `active` and `syncable`, so if the enqueue never lands the connection is
# left stuck: never synced again, shown as "Deletion in progress" indefinitely,
# with no job coming to delete it. DestroyJob's own rescue only covers a failure
# once the job is running; the enqueue side is handled here.
#
# perform_later can raise (the Sidekiq adapter re-raises RedisClient errors when
# Redis is unreachable) or return false (an enqueue callback aborting, or an
# adapter raising ActiveJob::EnqueueError). Both restore the flag.
#
# Both writes use update_column, skipping validations (item models declare no
# save callbacks for it to skip). Setting the flag must not fail on a validation
# unrelated to deletion: BrexItem checks base_url against an allowlist on every
# save, so a row that predates an allowlist change would otherwise be
# undeletable. Restoring it must not fail on one that depends on the flag --
# QuestradeItem skips its refresh_token presence check while
# scheduled_for_deletion is set -- and mask the enqueue error with its own.
#
# Don't call this inside a transaction: ApplicationJob defers enqueues until
# commit, so perform_later would return before the push is attempted and a
# failure would surface after this method has already returned.
module DestroyableLater
  extend ActiveSupport::Concern

  def destroy_later
    claimed = claim_scheduled_for_deletion

    enqueued = begin
      DestroyJob.perform_later(self)
    rescue StandardError
      restore_scheduled_for_deletion if claimed
      raise
    end

    # perform_later returns the job or false. Match false exactly: a bare mock of
    # perform_later returns nil, and treating that as a failure would clear the
    # flag in every test that only expects the enqueue.
    restore_scheduled_for_deletion if claimed && enqueued == false
    enqueued
  end

  private
    # Sets the flag under a row lock and reports whether this call set it.
    #
    # An item that is already flagged is still re-enqueued: that is how a
    # connection stuck by an earlier lost enqueue gets deleted. But a failure
    # here must not clear a flag an earlier request set, whose DestroyJob may
    # already be queued.
    #
    # The lock can't be held across the enqueue (see above), so one overlap
    # remains: this call claims, a concurrent call enqueues successfully, then
    # this call's enqueue fails and clears the flag. The queued DestroyJob still
    # destroys the item; the connection just reappears until it runs.
    def claim_scheduled_for_deletion
      with_lock do
        next false if scheduled_for_deletion?

        update_column(:scheduled_for_deletion, true)
        true
      end
    end

    def restore_scheduled_for_deletion
      update_column(:scheduled_for_deletion, false)
    end
end
