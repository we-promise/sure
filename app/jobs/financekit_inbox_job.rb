class FinancekitInboxJob < ApplicationJob
  queue_as :high_priority

  def perform(item_id = nil)
    items = item_id ? FinancekitItem.where(id: item_id) : FinancekitItem.where(status: "active")
    items.find_each do |item|
      next unless Financekit.enabled?(item.family)

      applied = []
      Financekit::MAX_QUEUED.times do
        batch = Financekit::Processor.new(item).apply_next!
        break unless batch

        applied << batch
      end
      Financekit::Downstream.new(applied).perform!
    end
    recover_lost_downstream_work!
    FinancekitBatch.where(status: %w[applied failed revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(payload: nil).update_all(payload: nil, updated_at: Time.current)
  end

  private

    # A lost job leaves applied batches with no downstream work. Load one
    # publisher's backlog at a time so the sweep stays bounded.
    def recover_lost_downstream_work!
      pending = FinancekitBatch.where(status: "applied", downstream_completed_at: nil)
      pending.distinct.pluck(:financekit_item_id).each do |financekit_item_id|
        batches = pending.where(financekit_item_id: financekit_item_id).to_a
        next if batches.empty?
        next unless Financekit.enabled?(batches.first.financekit_item.family)

        Financekit::Downstream.new(batches).perform!
      end
    end
end
