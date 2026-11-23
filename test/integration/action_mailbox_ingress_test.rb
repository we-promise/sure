require "test_helper"

# The order mailbox is read over IMAP only. Action Mailbox's HTTP ingresses must not accept mail,
# or anyone could inject inbound emails past the IMAP sender checks.
class ActionMailboxIngressTest < ActionDispatch::IntegrationTest
  RAW_EMAIL = "From: someone@example.com\r\nTo: shop@example.com\r\nSubject: hi\r\n\r\nhello".freeze

  test "relay ingress rejects mail" do
    post "/rails/action_mailbox/relay/inbound_emails", params: RAW_EMAIL,
         headers: { "Content-Type" => "message/rfc822" }

    assert_rejected
  end

  {
    postmark: { "RawEmail" => RAW_EMAIL },
    mailgun: { "body-mime" => RAW_EMAIL, "timestamp" => Time.current.to_i, "token" => "t", "signature" => "s" },
    sendgrid: { "email" => RAW_EMAIL },
    mandrill: { "mandrill_events" => [ { "msg" => { "raw_msg" => RAW_EMAIL } } ].to_json }
  }.each do |ingress, params|
    test "#{ingress} ingress rejects mail" do
      path = ingress == :mailgun ? "/rails/action_mailbox/mailgun/inbound_emails/mime" : "/rails/action_mailbox/#{ingress}/inbound_emails"
      post path, params: params

      assert_rejected
    end
  end

  test "Action Mailbox jobs run on queues Sidekiq works" do
    assert_equal :medium_priority, Rails.application.config.action_mailbox.queues[:routing]
    assert_equal :low_priority, Rails.application.config.action_mailbox.queues[:incineration]
  end

  private
    def assert_rejected
      assert_includes [ 401, 403, 404, 422 ], response.status
      assert_equal 0, ActionMailbox::InboundEmail.count
    end
end
