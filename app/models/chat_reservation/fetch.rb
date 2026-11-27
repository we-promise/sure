require "sidekiq/fetch"

# Sidekiq rebuilds the queue list on every fetch (at least every 2 s), so
# dropping the held queues (ChatReservation::HELD_QUEUES) keeps those jobs in
# their queues, in order. A job popped by a fetch that started before the hold
# goes back to the front of its queue. Only a single-threaded ai capsule holds:
# with more threads, one is free for the chat anyway. The ai_chat capsule polls
# none of them.
class ChatReservation::Fetch < Sidekiq::BasicFetch
  HELD = ChatReservation::HELD_QUEUES.map { "queue:#{_1}" }.freeze

  def queues_cmd
    queues = super
    holds?(queues) ? queues - HELD : queues
  end

  def retrieve_work
    work = super
    return work unless HELD.include?(work&.queue) && holds?(HELD)

    work.requeue
    nil
  end

  private
    def holds?(queues)
      queues.intersect?(HELD) && config.concurrency == 1 && ChatReservation.held?
    end
end
