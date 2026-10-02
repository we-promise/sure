class FinancekitInboxJob < ApplicationJob
  queue_as :high_priority

  def perform(item_id = nil)
    items = item_id ? FinancekitItem.where(id: item_id) : FinancekitItem.where(status: "active")
    items.find_each do |item|
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
    recover_lost_purges!
    FinancekitBatch.where(status: %w[applied failed revoked]).where("updated_at < ?", 7.days.ago)
      .where.not(payload: nil).update_all(payload: nil, updated_at: Time.current)
  end

  private

    # A discard the family asked for outlives the job that was meant to carry it
    # out: the request is recorded on the connection, so an enqueue that never
    # landed or a job that died partway is finished here. Financekit::Purge is
    # resumable -- it skips lineages it has already discarded -- so repeating it
    # costs nothing but is never skipped.
    def recover_lost_purges!
      # Materialized rather than find_each: that would discard the order and the
      # bound, and the oldest request is the one that has been waiting.
      FinancekitItem.where.not(purge_requested_at: nil).where(purge_completed_at: nil)
        .order(:purge_requested_at).limit(Financekit::MAX_QUEUED).to_a.each do |item|
        Financekit::Purge.new(item).perform!
      rescue StandardError
        # Purge already recorded the failure and left the request standing for the
        # next sweep. One publisher's failure must not strand the others.
        next
      end
    end

    # A lost job leaves applied batches with no downstream work. Bounded per
    # pass and per publisher: the fan-out costs the same for one batch or many,
    # so a larger backlog simply clears over the following sweeps.
    def recover_lost_downstream_work!
      pending = FinancekitBatch.where(status: "applied", downstream_completed_at: nil)
      pending.distinct.pluck(:financekit_item_id).each do |financekit_item_id|
        item = FinancekitItem.find_by(id: financekit_item_id)
        next unless item

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
