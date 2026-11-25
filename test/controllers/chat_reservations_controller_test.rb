require "test_helper"

class ChatReservationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    use_ai_routes(chat: %w[gpu/qwen3-8b])
  end

  test "typing holds chat's host and shows ready while other AI work is put off" do
    publish(put_off: true)

    post chat_reservation_url, as: :turbo_stream

    assert_response :success
    assert ChatReservation.held?("gpu.local:8080")
    assert_select "turbo-stream[action=update][targets='.chat-reservation'] template", text: /put off some background tasks/
  end

  test "no bubble when no other AI work runs or waits" do
    post chat_reservation_url, as: :turbo_stream

    assert ChatReservation.held?("gpu.local:8080")
    assert_select "turbo-stream[action=update][targets='.chat-reservation'] template", text: ""
  end

  test "the bubble says busy while other AI work runs on the host" do
    publish(holders: [ Ai::Gate::Holder.new(lane: :background) ])

    post chat_reservation_url, as: :turbo_stream

    assert_select "turbo-stream[targets='.chat-reservation'] template", text: /#{Regexp.escape(I18n.t("chats.reservation.busy"))}/
  end

  test "a cloud chat model holds nothing" do
    use_ai_routes(chat: %w[openai/gpt-4.1-mini])
    Ai::SharedState.expects(:write).never

    post chat_reservation_url, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[targets='.chat-reservation'] template", text: ""
  end

  test "forbidden without AI consent" do
    users(:family_admin).update!(ai_enabled: false)
    ChatReservation.expects(:hold!).never

    post chat_reservation_url, as: :turbo_stream

    assert_response :forbidden
  end

  private
    def publish(holders: [], put_off: false)
      Ai::Gate::State.write("gpu.local:8080", holders:, waiters: [], interruptions: 0, put_off:)
    end
end
