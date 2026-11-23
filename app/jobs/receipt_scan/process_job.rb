class ReceiptScan::ProcessJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(receipt_scan)
    ReceiptScan::Processor.new(receipt_scan).process!
  end
end
