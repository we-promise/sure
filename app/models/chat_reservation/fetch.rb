require "sidekiq/fetch"

# Sidekiq rebuilds the queue list on every fetch (at least every 2 s), so
# dropping ai_low_priority holds those jobs in their queue, in order.
class ChatReservation::Fetch < Sidekiq::BasicFetch
  LOW_QUEUE = "queue:ai_low_priority".freeze

  def queues_cmd
    queues = super
    return queues unless queues.include?(LOW_QUEUE)

    redis { |conn| conn.call("EXISTS", ChatReservation::KEY) } == 1 ? queues - [ LOW_QUEUE ] : queues
  end
end
