require "test_helper"

# The lane rules at a local model host's gate (Ai::Gate, ai-plumbing-redesign.md §11) and where
# it sits: in RubyLLM's instrumenter, around each request to a local endpoint. The interrupt
# itself, against a real socket, is test/models/ai/gate_interrupt_test.rb.
class AiGateTest < ActiveSupport::TestCase
  # A request holding a place in another thread until `release`.
  class Occupant
    attr_reader :holder, :error

    def initialize(gate, lane)
      @admitted = Queue.new
      @released = Queue.new
      @thread = Thread.new do
        gate.hold(lane) do
          @holder = Ai::Gate.holder
          @admitted << true
          @released.pop
        end
      rescue StandardError => error
        @error = error
        @admitted << false
      end
    end

    # Whether it got a place within `timeout` seconds.
    def admitted?(timeout: 2) = @admitted.pop(timeout:) == true

    def release
      @released << true
      @thread.join(2)
    end

    def stop = @thread.kill.join(2)
  end

  setup do
    @occupants = []
  end

  teardown do
    @occupants.each(&:stop)
  end

  test "waiters get places in lane order, then in arrival order" do
    gate = Ai::Gate.new(1)
    first = occupy(gate, :interactive)
    order = Queue.new
    waiters = [ [ :prompt, "prompt 1" ], [ :prompt, "prompt 2" ], [ :interactive, "interactive" ] ].map do |lane, name|
      thread = Thread.new { gate.hold(lane) { order << name } }
      wait_until { gate.waiters.size == (name == "prompt 1" ? 1 : name == "prompt 2" ? 2 : 3) }
      thread
    end

    first.release
    waiters.each { _1.join(2) }

    assert_equal [ "interactive", "prompt 1", "prompt 2" ], Array.new(3) { order.pop(timeout: 1) }
  end

  test "an interactive request interrupts the lowest running lane, background before prompt" do
    gate = Ai::Gate.new(3)
    prompt = occupy(gate, :prompt)
    background = occupy(gate, :background)
    occupy(gate, :interactive)

    waiting = occupy(gate, :interactive, admitted: false)

    assert_predicate background.holder, :preempted?
    assert_not_predicate prompt.holder, :preempted?

    background.release
    assert waiting.admitted?
  end

  test "a second waiting interactive request interrupts the next lowest" do
    gate = Ai::Gate.new(3)
    prompt = occupy(gate, :prompt)
    background = occupy(gate, :background)
    occupy(gate, :interactive)

    occupy(gate, :interactive, admitted: false)
    occupy(gate, :interactive, admitted: false)

    assert_predicate background.holder, :preempted?
    assert_predicate prompt.holder, :preempted?
  end

  test "an interactive request never interrupts another interactive one" do
    gate = Ai::Gate.new(1)
    running = occupy(gate, :interactive)

    waiting = occupy(gate, :interactive, admitted: false)

    assert_not_predicate running.holder, :preempted?
    running.release
    assert waiting.admitted?
  end

  test "a background request raises Busy instead of waiting" do
    gate = Ai::Gate.new(1)
    occupy(gate, :prompt)

    assert_raises(Ai::Error::Busy) { gate.hold(:background) { flunk "it shouldn't run" } }
  end

  test "a background request raises Busy while a prompt request waits, with the interactive place free" do
    gate = Ai::Gate.new(2)
    occupy(gate, :background)
    occupy(gate, :prompt, admitted: false)

    assert_raises(Ai::Error::Busy) { gate.hold(:background) { flunk "it shouldn't run" } }
  end

  test "with two or more places, one is kept for interactive requests" do
    gate = Ai::Gate.new(2)
    occupy(gate, :background)

    occupy(gate, :prompt, admitted: false)
    assert_raises(Ai::Error::Busy) { gate.hold(:background) { } }
    assert occupy(gate, :interactive).holder
  end

  test "one place serves every lane" do
    gate = Ai::Gate.new(1)

    assert_equal :ran, gate.hold(:background) { :ran }
    assert_equal :ran, gate.hold(:prompt) { :ran }
  end

  test "yields how long the request waited for its place" do
    gate = Ai::Gate.new(1)
    running = occupy(gate, :interactive)
    waited = Queue.new
    thread = Thread.new { gate.hold(:prompt) { waited << _1 } }
    wait_until { gate.waiters.any? }

    sleep 0.2
    running.release
    thread.join(2)

    assert_operator waited.pop(timeout: 1), :>=, 0.2
  end

  test "a request cancelled while it waited isn't sent" do
    gate = Ai::Gate.new(1)

    assert_raises(Ai::Error::Cancelled) { gate.hold(:prompt, cancelled: -> { true }) { flunk "it shouldn't run" } }
    assert_empty gate.holders
  end

  test "a place is freed when its request raises" do
    gate = Ai::Gate.new(1)

    assert_raises(RuntimeError) { gate.hold(:prompt) { raise "boom" } }
    assert_empty gate.holders
  end

  test "a local endpoint's requests pass its host's gate; a cloud endpoint has none" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    cloud = ai_endpoint(base_url: "https://llm.example.test/v1")

    assert_kind_of Ai::Gate::Holder, Ai::Transport::Instrumenter.new(nil, endpoint: local).instrument("request.ruby_llm", {}) { Ai::Gate.holder }
    assert_nil Ai::Transport::Instrumenter.new(nil, endpoint: cloud).instrument("request.ruby_llm", {}) { Ai::Gate.holder }
    assert_nil Ai::Sequencer.gate_for(cloud)
  end

  test "endpoints on one host share its gate, whichever port they use" do
    gpu = ai_endpoint(name: "gpu", base_url: "http://gpu.local:8080/v1", location: :local)
    sibling = gpu.with(name: "gpu_large")
    embed = gpu.with(name: "embed", base_url: "http://gpu.local:8081/v1")
    other = gpu.with(name: "other", base_url: "http://other.local:8080/v1")

    assert_same Ai::Sequencer.gate_for(gpu), Ai::Sequencer.gate_for(sibling)
    assert_same Ai::Sequencer.gate_for(gpu), Ai::Sequencer.gate_for(embed)
    assert_not_same Ai::Sequencer.gate_for(gpu), Ai::Sequencer.gate_for(other)
  end

  test "a host's gate has as many places as its smallest server has slots" do
    chat = ai_endpoint(name: "chat", base_url: "http://gpu.local:8080/v1", location: :local, parallel_requests: 4)
    embed = ai_endpoint(name: "embed", base_url: "http://gpu.local:8081/v1", location: :local, parallel_requests: 2)

    assert_equal 4, Ai::Sequencer.gate_for(chat).size
    assert_equal 2, Ai::Sequencer.gate_for(embed).size
    assert_equal 2, Ai::Sequencer.gate_for(chat).size
  end

  test "a request holds its place in the lane of the job that sent it" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    instrumenter = Ai::Transport::Instrumenter.new(nil, endpoint: local)

    lane = Ai::Sequencer.with_lane(:prompt) { instrumenter.instrument("request.ruby_llm", {}) { Ai::Gate.holder.lane } }

    assert_equal :prompt, lane
  end

  test "a background request to a full host raises Busy before it's sent" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    occupy(Ai::Sequencer.gate_for(local), :interactive)

    assert_raises(Ai::Error::Busy) do
      Ai::Sequencer.with_lane(:background) do
        Ai::Transport::Instrumenter.new(nil, endpoint: local).instrument("request.ruby_llm", {}) { flunk "it shouldn't be sent" }
      end
    end
  end

  test "time spent waiting at the gate isn't spent from the call's budget" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    running = occupy(Ai::Sequencer.gate_for(local), :interactive)
    instrumenter = Ai::Transport::Instrumenter.new(nil, endpoint: local)
    result = Queue.new

    thread = Thread.new do
      with_ai_call_context(model: ai_model(endpoint: local), budget: 0.3) do
        Ai::Sequencer.with_lane(:prompt) { instrumenter.instrument("request.ruby_llm", {}) { result << Ai::CallContext.current.remaining } }
      end
    rescue StandardError => error
      result << error
    end
    wait_until { Ai::Sequencer.gate_for(local).waiters.any? }
    sleep 0.5
    running.release
    thread.join(2)

    remaining = result.pop(timeout: 1)
    assert_kind_of Float, remaining, "the request shouldn't have timed out: #{remaining.inspect}"
    assert_operator remaining, :>, 0.1
  end

  test "an interrupted request's wait and run are each added to the deadline once, and it's sent again" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    running = occupy(Ai::Sequencer.gate_for(local), :interactive)
    transport = Ai::Transport::Compatible.new(local)
    instrumenter = Ai::Transport::Instrumenter.new(nil, endpoint: local)
    result = Queue.new

    thread = Thread.new do
      with_ai_call_context(model: ai_model(endpoint: local), budget: 30) do
        before = Ai::CallContext.current.deadline
        sent = 0
        Ai::Sequencer.with_lane(:prompt) do
          transport.send(:attempt) do
            transport.send(:mapping_errors) do
              instrumenter.instrument("request.ruby_llm", {}) do
                sent += 1
                next if sent > 1

                sleep 0.2
                raise Ai::Gate::Interrupted, "an interactive request needed the model host"
              end
            end
          end
        end
        result << [ sent, Ai::CallContext.current.deadline - before ]
      end
    rescue StandardError => error
      result << error
    end
    wait_until { Ai::Sequencer.gate_for(local).waiters.any? }
    sleep 0.3
    running.release
    thread.join(5)

    sent, moved = result.pop(timeout: 1)
    assert_equal 2, sent
    assert_in_delta 0.5, moved, 0.15, "0.3 s waiting plus 0.2 s running, each once"
  end

  test "the call's cancel check runs once the request has a place" do
    local = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)

    assert_raises(Ai::Error::Cancelled) do
      Ai::Sequencer.cancellable(-> { true }) do
        Ai::Transport::Instrumenter.new(nil, endpoint: local).instrument("request.ruby_llm", {}) { flunk "it shouldn't be sent" }
      end
    end
  end

  test "the gate's size is the endpoint's parallel_requests, or 1" do
    assert_equal 1, Ai::Sequencer.gate_for(ai_endpoint(base_url: "http://a.local:8080/v1", location: :local)).size
    assert_equal 4, Ai::Sequencer.gate_for(ai_endpoint(base_url: "http://b.local:8080/v1", location: :local, parallel_requests: 4)).size
  end

  test "the gate's size is llama.cpp's total_slots when /props answers" do
    Ai::Sequencer.ask_servers = true
    props = stub_request(:get, "http://gpu.local:8080/props").with(headers: { "Authorization" => "Bearer local-key" })
                                                            .to_return(status: 200, body: { total_slots: 3 }.to_json)

    gate = Ai::Sequencer.gate_for(ai_endpoint(base_url: "http://gpu.local:8080/v1", api_key: "local-key", location: :local, parallel_requests: 2))

    assert_equal 3, gate.size
    assert_requested props
  ensure
    Ai::Sequencer.ask_servers = false
  end

  test "a server without /props is sized by parallel_requests, and asked again after ten minutes" do
    Ai::Sequencer.ask_servers = true
    stub_request(:get, "http://ollama.local:11434/props").to_return(status: 404, body: "404 page not found")
    endpoint = ai_endpoint(base_url: "http://ollama.local:11434/v1", location: :local, parallel_requests: 2)
    gate = Ai::Sequencer.gate_for(endpoint)

    assert_equal 2, gate.size

    stub_request(:get, "http://ollama.local:11434/props").to_return(status: 200, body: { total_slots: 4 }.to_json)
    assert_equal 2, Ai::Sequencer.gate_for(endpoint).size
    Ai::Sequencer.stubs(:now).returns(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 11.minutes)
    assert_equal 4, Ai::Sequencer.gate_for(endpoint).size
  ensure
    Ai::Sequencer.ask_servers = false
  end

  test "an unreachable /props falls back to parallel_requests" do
    Ai::Sequencer.ask_servers = true
    stub_request(:get, "http://gpu.local:8080/props").to_raise(Faraday::ConnectionFailed.new("refused"))

    assert_equal 1, Ai::Sequencer.gate_for(ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)).size
  ensure
    Ai::Sequencer.ask_servers = false
  end

  test "a local Jev server's fan-out never asks for more places than its lane may hold" do
    jev = Ai::Transport::Jev.new(ai_endpoint(protocol: :jev, base_url: "http://jev.local:8090", location: :local, parallel_requests: 4))

    assert_equal 4, jev.parallel_requests
    assert_equal 3, Ai::Sequencer.with_lane(:background) { jev.parallel_requests }
    assert_equal 8, Ai::Transport::Jev.new(ai_endpoint(protocol: :jev)).parallel_requests
  end

  test "a local endpoint connects within ten seconds; a cloud one keeps RubyLLM's default" do
    local = Ai::Transport::Compatible.new(ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local, timeout_seconds: 300))
    short = Ai::Transport::Compatible.new(ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local, timeout_seconds: 4))
    cloud = Ai::Transport::Compatible.new(ai_endpoint(timeout_seconds: 300))

    assert_equal 10, local.send(:ruby_llm_context).config.connect_timeout
    assert_equal 4, short.send(:ruby_llm_context).config.connect_timeout
    assert_nil cloud.send(:ruby_llm_context).config.connect_timeout
  end

  private
    def occupy(gate, lane, admitted: true)
      waiting = gate.waiters.count { _1.lane == lane }
      Occupant.new(gate, lane).tap do |occupant|
        @occupants << occupant
        if admitted
          assert occupant.admitted?, "the #{lane} request should have a place (#{occupant.error.inspect})"
        else
          wait_until { gate.waiters.count { _1.lane == lane } > waiting }
        end
      end
    end

    def wait_until(timeout: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        flunk "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
    end
end
