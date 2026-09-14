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
# The restore uses update_column so it cannot fail on a validation that depends
# on the flag -- QuestradeItem skips its refresh_token presence check while
# scheduled_for_deletion is set -- and mask the enqueue error with its own.
#
# Don't call this inside a transaction: ApplicationJob defers enqueues until
# commit, so perform_later would return before the push is attempted and a
# failure would surface after this method has already returned.
module DestroyableLater
  extend ActiveSupport::Concern

  def destroy_later
    update!(scheduled_for_deletion: true)

    enqueued = begin
      DestroyJob.perform_later(self)
    rescue StandardError
      restore_scheduled_for_deletion
      raise
    end

    # perform_later returns the job or false. Match false exactly: a bare mock of
    # perform_later returns nil, and treating that as a failure would clear the
    # flag in every test that only expects the enqueue.
    restore_scheduled_for_deletion if enqueued == false
    enqueued
  end

  private
    def restore_scheduled_for_deletion
      update_column(:scheduled_for_deletion, false)
    end
end
