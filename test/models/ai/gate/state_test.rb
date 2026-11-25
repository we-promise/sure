require "test_helper"

# What a worker's gate publishes, and what the web reads of it.
class Ai::Gate::StateTest < ActiveSupport::TestCase
  setup do
    @endpoint = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    @gate = Ai::Sequencer.gate_for(@endpoint)
    Sidekiq.stubs(:server?).returns(true)
  end

  test "a worker publishes the requests that hold a place, and an empty gate after them" do
    Ai::CallContext.job("pdf_import:1") do
      @gate.hold(:prompt, feature: "extract_pdf") do
        assert_equal [ Ai::Gate::State::Request.new(lane: "prompt", feature: "extract_pdf", job: "pdf_import:1") ], state.holders
        assert_empty state.waiters
      end
    end

    assert_empty state.holders
  end

  test "a request is published while it waits, and an interruption is counted" do
    running = Thread.new { @gate.hold(:prompt) { sleep 0.01 until Ai::Gate.holder.preempted? } }
    sleep 0.01 until @gate.holders.any?
    prompt = Thread.new { Ai::CallContext.job("pdf_import:1") { @gate.hold(:prompt) { } } }
    sleep 0.01 until state&.waiters&.any?

    assert_equal [ "pdf_import:1" ], state.waiters.map(&:job)
    @gate.hold(:interactive) { }
    [ running, prompt ].each { _1.join(2) }

    assert_equal 1, state.interruptions
  end

  test "a refused background request leaves the line" do
    @gate.hold(:prompt) do
      Thread.new { assert_raises(Ai::Error::Busy) { @gate.hold(:background) { } } }.join

      assert_empty state.waiters
    end
  end

  test "a heartbeat refreshes a gate in use before its state expires; an idle gate's lapses" do
    @gate.hold(:prompt) do
      3.times do
        travel Ai::Gate::State::TTL - 1.second
        Ai::Sequencer.publish_gates
        assert_equal 1, state.holders.size
      end
    end

    travel Ai::Gate::State::TTL + 1.second
    Ai::Sequencer.publish_gates
    assert_nil state
  end

  test "a web process publishes nothing" do
    Sidekiq.stubs(:server?).returns(false)

    @gate.hold(:prompt) { assert_nil state }
  end

  test "a request isn't failed by a store that can't be written, and the web reads no gate from it" do
    Ai::SharedState.store = stub.tap do |store|
      store.stubs(:write).raises(RedisClient::ConnectionError)
      store.stubs(:read).raises(RedisClient::ConnectionError)
    end

    assert_equal :sent, @gate.hold(:prompt) { :sent }
    assert_nil state
  end

  test "a cloud endpoint has no gate to read" do
    assert_nil BackgroundJobHealth.model_gate(ai_endpoint)
    assert_nil BackgroundJobHealth.model_gate(nil)
  end

  test "an interactive job waits for the other interactive requests, not for work it interrupts" do
    chat, other, batch = request("interactive", "chat:1"), request("interactive", "chat:2"), request("background", "run:1")

    assert_equal 0, built(holders: [ batch ]).ahead_of("chat:1")
    assert_equal 1, built(holders: [ other ]).ahead_of("chat:1")
    assert_equal 1, built(holders: [ batch ], waiters: [ chat ]).ahead_of("chat:1"), "the interrupted request is letting go"
    assert_equal 1, built(holders: [ other ], waiters: [ chat ]).ahead_of("chat:1")
    assert_equal 0, built(holders: [ chat ], waiters: [ other ]).ahead_of("chat:1"), "it's running"
  end

  private
    def state = BackgroundJobHealth.model_gate(@endpoint)

    def request(lane, job) = { lane:, feature: nil, job: }

    def built(holders: [], waiters: []) = Ai::Gate::State.new({ holders:, waiters:, interruptions: 0 })
end
