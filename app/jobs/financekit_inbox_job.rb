class FinancekitInboxJob < ApplicationJob
  queue_as :scheduled

  def perform
    # A database inbox, not Redis enqueue success, is the recovery source of truth.
    FinancekitItem.where(status: "active").find_each do |item|
      next unless Financekit.enabled?(item.family)
      Financekit::MAX_QUEUED.times do
        break unless Financekit::Processor.new(item).apply_next!
      end
    end
    FinancekitBatch.where(status: "applied", downstream_completed_at: nil).find_each do |batch|
      next unless Financekit.enabled?(batch.financekit_item.family)
      begin
        Financekit::Downstream.new(batch).perform!
      rescue StandardError
        # Keep the durable outbox for the next sweep and isolate an unavailable
        # queue/provider from other families. Exception text can contain money.
        DebugLogEntry.capture(category: "provider_sync", level: "error", message: "FinanceKit downstream processing will retry",
          source: self.class.name, provider_key: "financekit", family: batch.financekit_item.family,
          metadata: { batch_id: batch.batch_id, error_code: "downstream_error" })
      end
    end
    FinancekitBatch.where(status: %w[applied revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(envelope: nil).update_all(envelope: nil)
  end
end
