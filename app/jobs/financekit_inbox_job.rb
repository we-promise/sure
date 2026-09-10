class FinancekitInboxJob < ApplicationJob
  queue_as :scheduled

  def perform
    # A database inbox, not Redis enqueue success, is the recovery source of truth.
    FinancekitItem.where(status: "active").find_each do |item|
      next unless Financekit.enabled?(item.family)
      Financekit::Processor.new(item).apply_next!
    end
    FinancekitBatch.where(status: "applied", downstream_completed_at: nil).find_each do |batch|
      next unless Financekit.enabled?(batch.financekit_item.family)
      Financekit::Downstream.new(batch).perform!
    end
    FinancekitBatch.where(status: %w[applied revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(envelope: nil).update_all(envelope: nil)
  end
end
