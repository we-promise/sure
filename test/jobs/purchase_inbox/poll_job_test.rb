require "test_helper"

class PurchaseInbox::PollJobTest < ActiveJob::TestCase
  test "does nothing when the mailbox isn't configured" do
    PurchaseInbox.stubs(:configured?).returns(false)
    PurchaseInbox::Poller.expects(:new).never

    PurchaseInbox::PollJob.perform_now
  end

  test "records a successful poll" do
    PurchaseInbox.stubs(:configured?).returns(true)
    PurchaseInbox::Poller.any_instance.stubs(:poll!).returns(2)
    PurchaseInbox.expects(:record_poll!).with(error: nil)

    PurchaseInbox::PollJob.perform_now
  end

  test "records and logs a connection error without the password" do
    Setting.purchase_inbox_password = "secret"
    PurchaseInbox.stubs(:configured?).returns(true)
    PurchaseInbox::Poller.any_instance.stubs(:poll!).raises(SocketError, "getaddrinfo: nodename nor servname provided")

    assert_difference -> { DebugLogEntry.where(source: "PurchaseInbox::PollJob").count }, 1 do
      PurchaseInbox::PollJob.perform_now
    end

    assert_match "getaddrinfo", Setting.purchase_inbox_last_error
    entry = DebugLogEntry.where(source: "PurchaseInbox::PollJob").last
    refute_includes entry.metadata.to_json, "secret"
    refute_includes entry.message, "secret"
  ensure
    Setting.purchase_inbox_password = nil
    Setting.purchase_inbox_last_error = nil
  end
end
