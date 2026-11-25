# One local model host's places for requests (ai-plumbing-redesign.md §11). Every request to a
# local endpoint holds a place while it runs (Ai::Transport::Instrumenter), so a host serves as
# many requests at once as it has slots, in lane order (Ai::Sequencer.lane):
#
# - interactive: waits first in line. When the host is full, it interrupts the running request
#   of the lowest lane, background before prompt, by shutting its connection. It never
#   interrupts another interactive request.
# - prompt: waits after interactive requests, in arrival order.
# - background: never waits. With no place free, or anyone waiting, it raises Ai::Error::Busy,
#   and its job comes back later.
#
# While someone types in the chat box (ChatReservation), no new prompt or background request
# starts on chat's host: the prompt request waits, and the background one raises Busy.
#
# With two or more places, one is kept for interactive requests. A gate lives in one worker's
# memory (Ai::Sequencer.gate_for), so a worker that dies takes its places with it. The worker
# publishes it for the web to read (Ai::Gate::State).
class Ai::Gate
  RANKS = { interactive: 0, prompt: 1, background: 2 }.freeze
  # Seconds between a waiting prompt request's checks whether the typing hold is over.
  HOLD_CHECK = 1

  # Raised in the interrupted request's adapter (Ai::Transport::Http::ProxyNetHttp). A
  # RubyLLM::CancelledError, so RubyLLM records that request's usage as cancelled, not failed;
  # the transport maps it to Ai::Error::Preempted.
  class Interrupted < RubyLLM::CancelledError; end

  # One request holding a place, or waiting for one. The interrupt shuts the request's own
  # socket, never RubyLLM's Faraday connection, which every thread shares. `shutdown` wakes a
  # read blocked in another thread, and the sending thread closes the socket as it unwinds.
  class Holder
    attr_reader :lane, :feature, :job, :arrival, :since

    # job: the correlation id of the job sending the request (Ai::CallContext.job).
    def initialize(lane:, feature: nil, job: nil, arrival: 0)
      raise ArgumentError, "unknown lane: #{lane.inspect}" unless RANKS.key?(lane)

      @lane = lane
      @feature = feature
      @job = job
      @arrival = arrival
      @lock = Mutex.new
      @preempted = false
    end

    def interactive? = lane == :interactive
    def rank = RANKS.fetch(lane)
    def preempted? = @preempted

    def admitted!
      @since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Called once the request's connection is open. A request interrupted before that is shut at once.
    def connected(socket)
      @lock.synchronize do
        @socket = socket
        shut(socket) if @preempted
      end
    end

    def interrupt
      @lock.synchronize do
        @preempted = true
        shut(@socket) if @socket
      end
    end

    private
      def shut(socket)
        socket.to_io.shutdown(Socket::SHUT_RDWR)
      rescue IOError, SystemCallError
        # Already closed: the request has finished or failed on its own.
      end
  end

  # Net::HTTP reports the connection it opens to the request's holder. Net::HTTP has no public
  # reader for its socket, so this reads `@socket`; test/models/ai/gate_interrupt_test.rb pins it.
  module Watched
    attr_accessor :ai_gate_holder

    private
      def connect
        super
        ai_gate_holder.connected(@socket.io)
      end
  end

  class << self
    # The holder of the request this fiber is sending, if it holds a place.
    def holder = Fiber[:ai_gate_holder]

    def holding(holder)
      previous = Fiber[:ai_gate_holder]
      Fiber[:ai_gate_holder] = holder
      yield
    ensure
      Fiber[:ai_gate_holder] = previous
    end

    # For ProxyNetHttp: a connection opened for a request that holds a place reports its socket.
    def watch(http)
      holder = self.holder
      http.extend(Watched).ai_gate_holder = holder if holder
      http
    end
  end

  attr_reader :size

  # host: the key it's published under (Ai::Sequencer.host_key); a gate without one isn't.
  def initialize(size, host: nil)
    @size = Integer(size)
    @host = host
    @monitor = Monitor.new
    @publishing = Mutex.new
    @changed = @monitor.new_cond
    @holders = []
    @waiters = []
    @arrivals = 0
    @interruptions = 0
    @put_off = false
  end

  def size=(size)
    @monitor.synchronize do
      @size = Integer(size)
      @changed.broadcast
    end
  end

  # How many places requests of `lane` may hold at once.
  def places_for(lane) = lane == :interactive || size < 2 ? size : size - 1

  def holders = @monitor.synchronize { @holders.dup }
  def waiters = @monitor.synchronize { @waiters.dup }
  def in_use? = @monitor.synchronize { @holders.any? || @waiters.any? }

  # Writes the gate's state for the web, never under the gate's lock and never failing the request.
  # Only a worker's, which its heartbeat keeps current: a web process's would overwrite it.
  def publish
    return unless @host && Sidekiq.server?

    # The state is taken in turn, so the last one written is the latest.
    @publishing.synchronize { State.write(@host, **@monitor.synchronize { state }) }
  rescue StandardError => e
    Rails.logger.warn("[Ai::Gate] state of #{@host} not published: #{e.class}: #{e.message}")
  end

  # Runs the block holding a place and yields the seconds it waited for one. Raises
  # Ai::Error::Busy for a background request that would wait, and Ai::Error::Cancelled when
  # `cancelled` answers true once a place is free, before the request is sent.
  def hold(lane, feature: nil, cancelled: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    holder = enter(lane, feature)
    begin
      raise Ai::Error::Cancelled, "cancelled while waiting for the model host" if cancelled&.call

      self.class.holding(holder) { yield Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    ensure
      leave(holder)
    end
  end

  private
    def enter(lane, feature)
      holder = join(lane, feature)
      begin
        publish
        publish until admitted?(holder, held: held?(holder))
      ensure
        left_the_line(holder)
        publish
      end
      holder
    end

    def join(lane, feature)
      @monitor.synchronize do
        holder = Holder.new(lane:, feature:, job: Ai::CallContext.correlation_id, arrival: @arrivals += 1)
        @waiters << holder
        @waiters.sort_by! { [ _1.rank, _1.arrival ] }
        holder
      end
    end

    # Whether the typing hold keeps the request off the host. Read before the gate's lock is taken,
    # so a slow Redis never keeps other requests from it.
    def held?(holder)
      !holder.interactive? && @host && ChatReservation.held?(@host)
    rescue StandardError => e
      Rails.logger.warn("[Ai::Gate] typing hold of #{@host} not read: #{e.class}: #{e.message}")
      false
    end

    # Gives the request its place if it's next, there's room and no hold keeps it off. Otherwise it
    # waits for the gate to change before it answers; a background request raises Busy instead.
    def admitted?(holder, held:)
      @monitor.synchronize do
        if !held && @waiters.first.equal?(holder) && room_for?(holder)
          @waiters.delete(holder)
          @holders << holder
          @put_off = false unless holder.interactive?
          holder.admitted!
          next true
        end
        @put_off = true if held
        raise Ai::Error::Busy, "the local model host is busy" if holder.lane == :background

        interrupt_for_interactive
        @changed.wait(held ? HOLD_CHECK : nil)
        false
      end
    end

    def left_the_line(holder)
      @monitor.synchronize do
        @waiters.delete(holder)
        @changed.broadcast
      end
    end

    def leave(holder)
      @monitor.synchronize do
        @holders.delete(holder)
        @changed.broadcast
      end
      publish
    end

    def state = { holders: @holders.dup, waiters: @waiters.dup, interruptions: @interruptions, put_off: @put_off }

    def room_for?(holder)
      return false if @holders.size >= size

      holder.interactive? || @holders.count { !_1.interactive? } < places_for(holder.lane)
    end

    # One running request per waiting interactive one, from the lowest lane, newest first: it has
    # the least work to lose. One already interrupted counts until it leaves.
    def interrupt_for_interactive
      wanted = @waiters.count(&:interactive?) - @holders.count(&:preempted?) - [ size - @holders.size, 0 ].max
      return unless wanted.positive?

      @holders.reject { _1.interactive? || _1.preempted? }
              .sort_by { [ -_1.rank, -_1.since ] }
              .first(wanted)
              .each do |holder|
                @interruptions += 1
                holder.interrupt
              end
    end
end
