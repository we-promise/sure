# A worker's gate as it last published it (Ai::Gate#publish), in Ai::SharedState: the requests
# holding a place and waiting for one, and how many it has interrupted. It's what the web knows
# of a local model host (BackgroundJobHealth.model_gate). Expires, so a dead worker's lapses.
class Ai::Gate::State
  # Three heartbeats of the worker that refreshes it.
  TTL = 30.seconds

  Request = Data.define(:lane, :feature, :job) do
    def interactive? = lane == "interactive"
  end

  class << self
    def write(host, holders:, waiters:, **attributes)
      requests = { holders:, waiters: }.transform_values { |list| list.map { { lane: _1.lane, feature: _1.feature, job: _1.job } } }
      Ai::SharedState.write(key(host), { **requests, **attributes }, expires_in: TTL)
    end

    # The host's state, or nil when no worker's gate there is in use.
    def read(host)
      attributes = Ai::SharedState.read(key(host))
      new(attributes.deep_symbolize_keys) if attributes
    end

    private
      def key(host) = "ai/gates/#{host}"
  end

  attr_reader :holders, :waiters, :interruptions

  def initialize(attributes)
    @holders, @waiters = attributes.values_at(:holders, :waiters).map { |list| list.map { Request.new(**_1) } }
    @interruptions = attributes[:interruptions]
  end

  def interactive? = (holders + waiters).any?(&:interactive?)

  # The requests a job's interactive request has to wait for: the other interactive ones, or the
  # interrupted one still letting go of its place.
  def ahead_of(job)
    return 0 if holders.any? { _1.job == job }

    others = (holders + waiters).count { _1.interactive? && _1.job != job }
    waiters.any? { _1.job == job } ? [ others, 1 ].max : others
  end
end
