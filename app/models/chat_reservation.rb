# Focusing or typing in the chat box keeps the local model host chat uses free for the message: for
# TTL, no new prompt or background request starts there (Ai::Gate), so a long prompt read rarely
# starts just before the message is sent. Back-to-back holds stop CAP after the first one and
# resume TTL later, so that work gets a turn. The message ends its host's hold.
module ChatReservation
  TARGETS = ".chat-reservation".freeze
  TTL = 60.seconds
  CAP = 15.minutes

  class << self
    # Returns the seconds held, or nil when nothing is: chat's model isn't local (no endpoint), or
    # the cap was reached.
    def hold!(endpoint)
      return unless endpoint

      host = Ai::Sequencer.host_key(endpoint)
      now = Time.current.to_i
      started = Ai::SharedState.read(started_key(host))
      if started.nil? || (now - started < CAP && !held?(host))
        started = now
        Ai::SharedState.write(started_key(host), now, expires_in: CAP + TTL)
      end

      seconds = [ TTL.to_i, started + CAP.to_i - now ].min
      return unless seconds.positive?

      Ai::SharedState.write(key(host), true, expires_in: seconds)
      seconds
    end

    def held?(host) = Ai::SharedState.read(key(host)).present?

    # Never fails the message: a hold left standing lapses by itself.
    def release(endpoint)
      Ai::SharedState.delete(key(Ai::Sequencer.host_key(endpoint)))
    rescue StandardError => e
      Rails.logger.warn("ChatReservation not released: #{e.class}: #{e.message}")
    end

    # Nothing while a chat request runs or waits: its own bubble covers that. Otherwise busy while
    # other AI work runs on the host, ready while some is put off. seconds comes from hold!.
    def bubble(endpoint, seconds)
      return if seconds.nil?

      gate = BackgroundJobHealth.model_gate(endpoint)
      return if gate.nil? || gate.interactive?

      busy = gate.holders.any?
      { seconds:, busy: } if busy || gate.put_off?
    end

    private
      def key(host) = "ai/hold/#{host}"

      def started_key(host) = "#{key(host)}/started"
  end
end
