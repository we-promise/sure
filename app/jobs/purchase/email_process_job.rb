class Purchase::EmailProcessJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(purchase)
    Purchase::EmailProcessor.new(purchase).process!
  end
end
