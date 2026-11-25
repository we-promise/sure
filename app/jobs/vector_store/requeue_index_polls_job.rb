# Restarts indexing polls that were lost when a queue rejected an initial or follow-up enqueue.
# A document still `processing` is safe to poll again, so this runs on a schedule.
class VectorStore::RequeueIndexPollsJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  def perform = FamilyDocument.requeue_index_polls
end
