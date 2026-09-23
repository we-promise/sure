class FinancekitInboxJob < ApplicationJob
  queue_as :high_priority

  def perform(item_id = nil)
    items = item_id ? FinancekitItem.where(id: item_id) : FinancekitItem.where(status: "active")
    items.find_each do |item|
      next unless Financekit.enabled?(item.family)

      # Ids only: a drained capture still holds its payload bytes.
      applied_ids = []
      Financekit::MAX_QUEUED.times do
        batch = Financekit::Processor.new(item).apply_next!
        break unless batch

        applied_ids << batch.id
      end
      Financekit::Downstream.new(item, FinancekitBatch.where(id: applied_ids)).perform!
    end
    recover_lost_downstream_work!
    FinancekitBatch.where(status: %w[applied failed revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(payload: nil).update_all(payload: nil, updated_at: Time.current)
  end

  private

    # A lost job leaves applied batches with no downstream work. Bounded per
    # pass and per publisher: the fan-out costs the same for one batch or many,
    # so a larger backlog simply clears over the following sweeps.
    def recover_lost_downstream_work!
      pending = FinancekitBatch.where(status: "applied", downstream_completed_at: nil)
      pending.distinct.pluck(:financekit_item_id).each do |financekit_item_id|
        item = FinancekitItem.find_by(id: financekit_item_id)
        next unless item && Financekit.enabled?(item.family)

        scope = pending.where(financekit_item_id: financekit_item_id).limit(Financekit::MAX_QUEUED)
        Financekit::Downstream.new(item, scope).perform!
      end
    end
end
