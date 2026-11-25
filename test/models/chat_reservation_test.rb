require "test_helper"

class ChatReservationTest < ActiveSupport::TestCase
  setup do
    @endpoint = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    @host = "gpu.local:8080"
    @reservation = ChatReservation.new([ @endpoint ], lanes: %i[prompt background])
  end

  test "hold! holds chat's host for the TTL" do
    assert_equal 60, @reservation.hold!
    assert ChatReservation.held?(@host, :background)
    assert_not ChatReservation.held?("gpu.local:8081", :background), "another server on that machine has its own gate"

    travel 61.seconds
    assert_not ChatReservation.held?(@host, :background)
  end

  test "without a local host for chat, nothing is held" do
    Ai::SharedState.expects(:write).never

    assert_nil ChatReservation.new([], lanes: %i[background]).hold!
  end

  test "a built-in chat holds both lanes of its own host, an external one background requests off every local host" do
    use_ai_routes(chat: %w[gpu/qwen3-8b agent/openclaw/main])
    user = users(:family_admin)
    user.family.update!(assistant_type: "builtin")
    ChatReservation.for(user).hold!
    assert_equal [ true, true, false ], held([ "gpu.local:8080", :prompt ], [ "gpu.local:8080", :background ], [ "embed.local:8081", :background ])

    ChatReservation.release(Ai::Sequencer.local_endpoints)
    user.family.update!(assistant_type: "external")
    assert_equal 60, ChatReservation.for(user).hold!
    assert_equal [ false, true, true ], held([ "gpu.local:8080", :prompt ], [ "gpu.local:8080", :background ], [ "embed.local:8081", :background ])
  end

  test "back-to-back holds stop at the cap and resume a TTL later" do
    travel_to Time.zone.parse("2026-10-23 09:00:00")
    29.times { @reservation.hold!; travel 30.seconds }
    travel_to Time.zone.parse("2026-10-23 09:14:30")
    assert_equal 30, @reservation.hold!

    travel_to Time.zone.parse("2026-10-23 09:15:00")
    assert_nil @reservation.hold!
    assert_not ChatReservation.held?(@host, :background)

    travel_to Time.zone.parse("2026-10-23 09:16:00")
    assert_equal 60, @reservation.hold!
  end

  test "a hold that lapsed, or that a message ended, starts a new cap" do
    travel_to Time.zone.parse("2026-10-23 09:00:00")
    @reservation.hold!
    travel_to Time.zone.parse("2026-10-23 09:14:50")
    assert_equal 60, @reservation.hold!

    ChatReservation.release([ @endpoint ])
    assert_not ChatReservation.held?(@host, :background)
    travel_to Time.zone.parse("2026-10-23 09:29:40")
    assert_equal 60, @reservation.hold!
  end

  test "the bubble says busy while other AI work runs on the host, ready while some is put off, else nothing" do
    assert_nil @reservation.bubble(60), "no worker's gate is in use"

    publish(holders: [ holder(:background) ])
    assert_equal({ seconds: 60, busy: true }, @reservation.bubble(60))
    assert_nil @reservation.bubble(nil), "nothing is held"

    publish(put_off: true)
    assert_equal({ seconds: 60, busy: false }, @reservation.bubble(60))

    publish
    assert_nil @reservation.bubble(60)
  end

  test "no bubble while a chat request runs or waits" do
    publish(holders: [ holder(:interactive) ], put_off: true)
    assert_nil @reservation.bubble(60)

    publish(holders: [ holder(:background) ], waiters: [ holder(:interactive) ])
    assert_nil @reservation.bubble(60)
  end

  private
    def held(*pairs) = pairs.map { |host, lane| ChatReservation.held?(host, lane) }

    def publish(holders: [], waiters: [], put_off: false)
      Ai::Gate::State.write(@host, holders:, waiters:, interruptions: 0, put_off:)
    end

    def holder(lane) = Ai::Gate::Holder.new(lane:)
end
