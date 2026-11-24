# One local model host's places for requests. This part is the interrupt: a request holding a
# place can be stopped from another thread by shutting its connection's socket, whether the
# server is still reading the prompt (nothing sent yet) or streaming the answer.
class Ai::Gate
  # Raised in the interrupted request's adapter (Ai::Transport::Http::ProxyNetHttp). A
  # RubyLLM::CancelledError, so RubyLLM records that request's usage as cancelled, not failed;
  # the transport maps it to Ai::Error::Preempted.
  class Interrupted < RubyLLM::CancelledError; end

  # One request holding a place. The interrupt shuts the request's own socket, never RubyLLM's
  # Faraday connection, which every thread shares. `shutdown` wakes a read blocked in another
  # thread, and the sending thread closes the socket itself as it unwinds.
  class Holder
    attr_reader :lane, :feature

    def initialize(lane:, feature: nil)
      @lane = lane
      @feature = feature
      @lock = Mutex.new
      @preempted = false
    end

    def preempted? = @preempted

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
end
