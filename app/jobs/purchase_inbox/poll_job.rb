# Reads new messages from the order mailbox (see PurchaseInbox::Poller).
class PurchaseInbox::PollJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  CONNECTION_ERRORS = [
    Net::IMAP::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, IOError
  ].freeze

  def perform
    return unless PurchaseInbox.configured?

    PurchaseInbox::Poller.new.poll!
    PurchaseInbox.record_poll!(error: nil)
  rescue *CONNECTION_ERRORS => e
    message = PurchaseInbox.redact(e.message)
    PurchaseInbox.record_poll!(error: message)
    DebugLogEntry.capture(
      category: "purchase_inbox",
      level: "error",
      message: "Order mailbox poll failed: #{message}",
      source: self.class.name,
      metadata: { error_class: e.class.name, host: Setting.purchase_inbox_host }
    )
  end
end
