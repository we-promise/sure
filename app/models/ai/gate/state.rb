# A worker's gate as it last published it (Ai::Gate#publish), in Ai::SharedState: the requests
# holding a place and waiting for one, how many it has interrupted, and whether a typing hold put
# any off that haven't started since. It's what the web knows of a local model host
# (BackgroundJobHealth.model_gate). Expires, so a dead worker's lapses.
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
    @interruptions, @put_off = attributes.values_at(:interruptions, :put_off)
  end

  def put_off? = @put_off

  def interactive? = (holders + waiters).any?(&:interactive?)

  def waiting?(job) = waiters.any? { _1.job == job }

  # Whether a job's request waits behind an interactive one. It interrupts the others.
  def behind_interactive?(job)
    waiting?(job) && (holders + waiters.take_while { _1.job != job }).any?(&:interactive?)
  end
end
