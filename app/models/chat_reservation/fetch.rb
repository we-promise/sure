require "sidekiq/fetch"

# Sidekiq rebuilds the queue list on every fetch (at least every 2 s), so
# dropping ai_low_priority holds those jobs in their queue, in order. A job
# popped by a fetch that started before the hold goes back to the front of
# its queue. Only a single-threaded AI capsule holds: with more threads, one
# is free for the chat anyway.
class ChatReservation::Fetch < Sidekiq::BasicFetch
  LOW_QUEUE = "queue:ai_low_priority".freeze

  def queues_cmd
    queues = super
    holds?(queues) ? queues - [ LOW_QUEUE ] : queues
  end

  def retrieve_work
    work = super
    return work unless work&.queue == LOW_QUEUE && holds?([ LOW_QUEUE ])

    work.requeue
    nil
  end

  private
    def holds?(queues)
      queues.include?(LOW_QUEUE) && config.concurrency == 1 && ChatReservation.held?
    end
end
