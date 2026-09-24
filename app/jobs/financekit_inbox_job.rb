class FinancekitInboxJob < ApplicationJob
  queue_as :high_priority

  def perform(item_id = nil)
    items = item_id ? FinancekitItem.where(id: item_id) : FinancekitItem.where(status: "active")
    items.find_each do |item|
      next unless Financekit.enabled?(item.family)

      # Ids only: a drained capture still holds its payload bytes. Every part of
      # a multi-chunk capture is collected, so none is left for the sweep below
      # to fan out a second time in this same run.
      applied_ids = []
      Financekit::MAX_QUEUED.times do
        parts = Financekit::Processor.new(item).apply_next!
        break if parts.blank?

        applied_ids.concat(parts.map(&:id))
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

        # Ordered because the limit makes the choice matter: without it Postgres
        # may return any MAX_QUEUED of the backlog, so the same rows can lose
        # every sweep while newer ones complete. Stream order is the publisher's
        # own order and matches the financekit_stream_sequence index.
        scope = pending.where(financekit_item_id: financekit_item_id)
          .order(:generation, :stream_id, :sequence).limit(Financekit::MAX_QUEUED)
        Financekit::Downstream.new(item, scope).perform!
      end
    end
end
