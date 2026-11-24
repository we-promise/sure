# Chat has its own thread, but with one thread for the other AI work a chat's
# model call can wait for a background job's on a local model. Focusing or
# typing in the chat box, and each finished reply, hold new prompt and
# background jobs back for TTL. Back-to-back holds stop CAP after the first one
# and resume TTL later, so those jobs get a turn.
module ChatReservation
  # Every AI queue but the interactive ones, which chat runs on.
  HELD_QUEUES = (Ai::Routes.ai_queues - Ai::Routes.queues_for_lane(:interactive)).freeze
  KEY = "chat_reservation".freeze
  STARTED_KEY = "chat_reservation:started".freeze
  CHAT_KEY = "chat_reservation:chat_running".freeze
  TARGETS = ".chat-reservation".freeze
  TTL = 60.seconds
  CAP = 15.minutes

  # Returns the seconds held, or nil when nothing is held: several AI threads
  # leave one free anyway, or the cap was reached.
  def self.hold!
    return unless BackgroundJobHealth.one_ai_thread?

    Sidekiq.redis do |conn|
      now = Time.current.to_i
      started = conn.call("GET", STARTED_KEY)&.to_i
      if started.nil? || (now - started < CAP && conn.call("EXISTS", KEY).zero?)
        started = now
        conn.call("SET", STARTED_KEY, now, "EX", (CAP + TTL).to_i)
      end

      seconds = [ TTL.to_i, started + CAP.to_i - now ].min
      next unless seconds.positive?

      conn.call("SET", KEY, "1", "EX", seconds)
      seconds
    end
  end

  # Marks a chat job as running, interim replies included. Expires with the
  # chat's response timeout in case the worker dies mid-job.
  def self.while_chat_runs
    begin
      Sidekiq.redis { |conn| conn.call("SET", CHAT_KEY, "1", "EX", Chat.response_timeout.to_i) }
    rescue => e
      Rails.logger.warn("ChatReservation chat flag not set: #{e.class}: #{e.message}")
    end
    yield
  ensure
    begin
      Sidekiq.redis { |conn| conn.call("DEL", CHAT_KEY) }
    rescue => e
      Rails.logger.warn("ChatReservation chat flag not cleared: #{e.class}: #{e.message}")
    end
  end

  def self.held?
    Sidekiq.redis { |conn| conn.call("EXISTS", KEY) } == 1
  end

  def self.chat_active?
    Sidekiq.redis { |conn| conn.call("EXISTS", CHAT_KEY) } == 1 || waiting?(Ai::Routes.queues_for_lane(:interactive))
  end

  # Nothing while a chat is queued or running: its own bubble covers that.
  # Otherwise busy while a background AI job runs, ready while some wait.
  # seconds comes from hold!, which has already checked for one AI thread.
  def self.bubble(seconds)
    return if seconds.nil? || chat_active?

    busy = BackgroundJobHealth.ai_job_running?(queues: HELD_QUEUES)
    { seconds: seconds, busy: busy } if busy || waiting?(HELD_QUEUES)
  end

  def self.waiting?(queues) = queues.any? { Sidekiq::Queue.new(_1).size.positive? }
  private_class_method :waiting?
end
