class EmailAlertMessageJob < ApplicationJob
  queue_as :high_priority

  # Imports the transaction right away, then lets an item sync anchor the
  # account balance and recalculate history.
  def perform(message)
    message.process!
    message.email_alert_item.sync_later if message.processed?
  end
end
