require "test_helper"

class ChatReservationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    BackgroundJobHealth.stubs(:ai_job_running?).with(queues: [ "ai_low_priority" ]).returns(false)
    ChatReservation.stubs(:chat_active?).returns(false)
    stub_waiting_jobs(1)
  end

  test "typing holds the reservation and shows ready while background AI jobs wait" do
    ChatReservation.expects(:hold!).returns(60)

    post chat_reservation_url, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=update][targets='.chat-reservation'] template", text: /put off some background tasks/
  end

  test "no bubble when no background AI job waits" do
    ChatReservation.expects(:hold!).returns(60)
    stub_waiting_jobs(0)

    post chat_reservation_url, as: :turbo_stream

    assert_select "turbo-stream[action=update][targets='.chat-reservation'] template", text: ""
  end

  test "the bubble says busy while a background AI job runs" do
    ChatReservation.expects(:hold!).returns(60)
    BackgroundJobHealth.stubs(:ai_job_running?).with(queues: [ "ai_low_priority" ]).returns(true)
    stub_waiting_jobs(0)

    post chat_reservation_url, as: :turbo_stream

    assert_select "turbo-stream[targets='.chat-reservation'] template", text: /#{Regexp.escape(I18n.t("chats.reservation.busy"))}/
  end

  test "forbidden without AI consent" do
    users(:family_admin).update!(ai_enabled: false)
    ChatReservation.expects(:hold!).never

    post chat_reservation_url, as: :turbo_stream

    assert_response :forbidden
  end

  private
    def stub_waiting_jobs(count)
      Sidekiq::Queue.stubs(:new).with("ai_low_priority").returns(stub(size: count))
    end
end
