# Syncable#sync_later now queues a follow-up for a request made while a
# sync runs, so this job no longer waits for the sync to finish. It stays for
# one release so that a job queued before then still makes its request; remove
# it after that.
class SophtronInitialLoadJob < ApplicationJob
  queue_as :high_priority

  def perform(sophtron_item, **)
    sophtron_item.sync_later
  end
end
