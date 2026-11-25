# Focusing or typing in the chat box keeps the local model hosts free for the message: for TTL, no
# new request of the held lanes starts there (Ai::Gate), so a long prompt read rarely starts just
# before the message is sent. Back-to-back holds stop CAP after the first one and resume TTL later,
# so that work gets a turn. The message ends the hold of the person who typed it.
#
# A built-in chat holds its model's host, if that's local. An external assistant calls its own
# models, which may be on any of the local hosts, so it holds new background requests off them all;
# prompt requests still start, since the assistant's own tools may need them.
class ChatReservation
  TARGETS = ".chat-reservation".freeze
  TTL = 60.seconds
  CAP = 15.minutes

  class << self
    def for(user)
      endpoint = Ai::Sequencer.chat_endpoint(user)
      return new([ endpoint ], lanes: %i[prompt background], user:) if endpoint

      new(Ai::Sequencer.external_chat?(user) ? Ai::Sequencer.local_endpoints : [], lanes: %i[background], user:)
    end

    def held?(host, lane) = Ai::SharedState.read(key(host, lane)).present?

    # Ends the user's own holds: the last to type on a host has its hold. Never fails the message: a
    # hold left standing lapses by itself.
    def release(endpoints, user:)
      keys = endpoints.map { Ai::Sequencer.host_key(_1) }.uniq.product(%i[prompt background]).map { key(*_1) }
      keys.each { |key| Ai::SharedState.delete(key) if Ai::SharedState.read(key) == user&.id }
    rescue StandardError => e
      Rails.logger.warn("ChatReservation not released: #{e.class}: #{e.message}")
    end

    def key(host, lane) = "ai/hold/#{host}/#{lane}"
  end

  def initialize(endpoints, lanes:, user:)
    @endpoints = endpoints.uniq { Ai::Sequencer.host_key(_1) }
    @lanes = lanes
    @user = user
  end

  # Returns the seconds held, or nil when nothing is: no local host, or the cap was reached.
  def hold! = @endpoints.filter_map { hold_host(Ai::Sequencer.host_key(_1)) }.max

  # Nothing while a chat request runs or waits: its own bubble covers that. Otherwise busy while
  # other AI work runs on a host, ready while some is put off. seconds comes from hold!.
  def bubble(seconds)
    return if seconds.nil?

    gates = @endpoints.filter_map { BackgroundJobHealth.model_gate(_1) }
    return if gates.any?(&:interactive?)

    busy = gates.any? { _1.holders.any? }
    { seconds:, busy: } if busy || gates.any?(&:put_off?)
  end

  private
    def hold_host(host)
      now = Time.current.to_i
      started = Ai::SharedState.read(started_key(host))
      if started.nil? || (now - started < CAP && !self.class.held?(host, :background))
        started = now
        Ai::SharedState.write(started_key(host), now, expires_in: CAP + TTL)
      end

      seconds = [ TTL.to_i, started + CAP.to_i - now ].min
      return unless seconds.positive?

      @lanes.each { |lane| Ai::SharedState.write(self.class.key(host, lane), @user.id, expires_in: seconds) }
      seconds
    end

    def started_key(host) = "ai/hold/#{host}/started"
end
