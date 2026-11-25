require "test_helper"

class ChatReservationTest < ActiveSupport::TestCase
  setup do
    @endpoint = ai_endpoint(base_url: "http://gpu.local:8080/v1", location: :local)
    @host = "gpu.local:8080"
  end

  test "hold! holds chat's host for the TTL" do
    assert_equal 60, ChatReservation.hold!(@endpoint)
    assert ChatReservation.held?(@host)
    assert_not ChatReservation.held?("gpu.local:8081"), "another server on that machine has its own gate"

    travel 61.seconds
    assert_not ChatReservation.held?(@host)
  end

  test "without a local host for chat, nothing is held" do
    Ai::SharedState.expects(:write).never

    assert_nil ChatReservation.hold!(nil)
  end

  test "back-to-back holds stop at the cap and resume a TTL later" do
    travel_to Time.zone.parse("2026-10-23 09:00:00")
    29.times { ChatReservation.hold!(@endpoint); travel 30.seconds }
    travel_to Time.zone.parse("2026-10-23 09:14:30")
    assert_equal 30, ChatReservation.hold!(@endpoint)

    travel_to Time.zone.parse("2026-10-23 09:15:00")
    assert_nil ChatReservation.hold!(@endpoint)
    assert_not ChatReservation.held?(@host)

    travel_to Time.zone.parse("2026-10-23 09:16:00")
    assert_equal 60, ChatReservation.hold!(@endpoint)
  end

  test "a hold that lapsed, or that a message ended, starts a new cap" do
    travel_to Time.zone.parse("2026-10-23 09:00:00")
    ChatReservation.hold!(@endpoint)
    travel_to Time.zone.parse("2026-10-23 09:14:50")
    assert_equal 60, ChatReservation.hold!(@endpoint)

    ChatReservation.release(@endpoint)
    assert_not ChatReservation.held?(@host)
    travel_to Time.zone.parse("2026-10-23 09:29:40")
    assert_equal 60, ChatReservation.hold!(@endpoint)
  end

  test "the bubble says busy while other AI work runs on the host, ready while some is put off, else nothing" do
    assert_nil ChatReservation.bubble(@endpoint, 60), "no worker's gate is in use"

    publish(holders: [ holder(:background) ])
    assert_equal({ seconds: 60, busy: true }, ChatReservation.bubble(@endpoint, 60))
    assert_nil ChatReservation.bubble(@endpoint, nil), "nothing is held"

    publish(put_off: true)
    assert_equal({ seconds: 60, busy: false }, ChatReservation.bubble(@endpoint, 60))

    publish
    assert_nil ChatReservation.bubble(@endpoint, 60)
  end

  test "no bubble while a chat request runs or waits" do
    publish(holders: [ holder(:interactive) ], put_off: true)
    assert_nil ChatReservation.bubble(@endpoint, 60)

    publish(holders: [ holder(:background) ], waiters: [ holder(:interactive) ])
    assert_nil ChatReservation.bubble(@endpoint, 60)
  end

  private
    def publish(holders: [], waiters: [], put_off: false)
      Ai::Gate::State.write(@host, holders:, waiters:, interruptions: 0, put_off:)
    end

    def holder(lane) = Ai::Gate::Holder.new(lane:)
end
