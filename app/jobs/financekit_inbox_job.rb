class FinancekitInboxJob < ApplicationJob
  queue_as :high_priority

  def perform(item_id = nil)
    items = item_id ? FinancekitItem.where(id: item_id) : FinancekitItem.where(status: "active")
    items.find_each do |item|
      next unless Financekit.enabled?(item.family)

      Financekit::MAX_QUEUED.times do
        break unless Financekit::Processor.new(item).apply_next!
      end
    end
    FinancekitBatch.where(status: "applied", downstream_completed_at: nil).find_each do |batch|
      next unless Financekit.enabled?(batch.financekit_item.family)

      Financekit::Downstream.new(batch).perform!
    end
    FinancekitBatch.where(status: %w[applied failed revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(payload: nil).update_all(payload: nil, updated_at: Time.current)
  end
end
