require "test_helper"

class Webhooks::EmailAlertsControllerTest < ActionDispatch::IntegrationTest
  include EmailAlertsTestHelper

  setup do
    @item = email_alert_items(:one)
  end

  test "stores an alert from a supported sender and queues processing" do
    assert_enqueued_with(job: EmailAlertMessageJob) do
      assert_difference -> { @item.email_alert_messages.count }, 1 do
        post_raw @item.inbound_token, email_alert_fixture("gtbank_credit")
      end
    end

    assert_response :accepted
    assert_equal "accepted", response.parsed_body["status"]
  end

  test "a redelivered alert is not queued twice" do
    post_raw @item.inbound_token, email_alert_fixture("gtbank_credit")
    @item.email_alert_messages.update_all(status: "processed")

    assert_no_enqueued_jobs(only: EmailAlertMessageJob) do
      assert_no_difference -> { @item.email_alert_messages.count } do
        post_raw @item.inbound_token, email_alert_fixture("gtbank_credit")
      end
    end
    assert_response :accepted
  end

  test "mail from other senders is answered with ignored and not stored" do
    raw = "From: forwarding-noreply@google.com\r\nSubject: Gmail Forwarding Confirmation\r\n\r\nConfirm\r\n"

    assert_no_difference -> { EmailAlertMessage.count } do
      post_raw @item.inbound_token, raw
    end

    assert_response :ok
    assert_equal "ignored", response.parsed_body["status"]
  end

  test "an unknown token is not found" do
    assert_no_difference -> { EmailAlertMessage.count } do
      post_raw "not-a-real-token", email_alert_fixture("gtbank_credit")
    end

    assert_response :not_found
  end

  test "a connection scheduled for deletion no longer accepts mail" do
    @item.update!(scheduled_for_deletion: true)

    post_raw @item.inbound_token, email_alert_fixture("gtbank_credit")

    assert_response :not_found
  end

  test "oversized messages are refused" do
    raw = email_alert_fixture("gtbank_credit") + ("x" * EmailAlert::MimeMessage::MAX_BYTES)

    post_raw @item.inbound_token, raw

    assert_response :content_too_large
  end

  private

    def post_raw(token, raw)
      post webhooks_email_alerts_path(token: token), params: raw, headers: { "CONTENT_TYPE" => "message/rfc822" }
    end
end
