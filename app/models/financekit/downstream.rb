class Financekit::Downstream
  ADVISORY_LOCK_SCOPE = "financekit_downstream".freeze

  # Takes a scope rather than loaded records and keeps only the ids. A pending
  # batch carries its payload — up to Financekit::MAX_BYTES, retained for seven
  # days — and an applied batch no longer counts against the inbox cap, so a
  # backlog awaiting downstream work has no ceiling of its own.
  def initialize(item, scope)
    @item = item
    @batch_ids = scope.where(downstream_completed_at: nil).pluck(:id)
  end

  def perform!
    return if @batch_ids.empty?

    with_publisher_claim do
      # Re-read inside the claim. Two workers can snapshot the same ids before
      # either runs — a per-upload job and the periodic sweep overlap this way —
      # and without this the second one repeats the whole family fan-out.
      pending = FinancekitBatch.where(id: @batch_ids, downstream_completed_at: nil).pluck(:id)
      next if pending.empty?

      # Scheduling and both completion writes in one transaction. Committing the
      # two writes separately left batches complete alongside stale publisher
      # health, which the recovery sweep then skipped because it only looks for
      # incomplete batches. Scheduling outside it was no better: a failed health
      # write rolled the batch back after the jobs were already queued, so
      # recovery ran the same rules again and RuleJob records a RuleRun per run.
      # Enqueueing from inside is safe here because ApplicationJob sets
      # enqueue_after_transaction_commit, so SyncJob and RuleJob are deferred to
      # the commit and dropped outright if it rolls back.
      #
      # The fan-out itself costs the same whether one capture or fifty just
      # landed, so a drain pays for it once rather than once per capture.
      completed_at = Time.current
      FinancekitBatch.transaction do
        @item.selected_accounts.includes(financekit_account_lineage: :account).find_each do |mapping|
          mapping.account&.sync_later
        end
        @item.family.auto_match_transfers!
        @item.family.rules.where(active: true).find_each(&:apply_later)

        FinancekitBatch.where(id: pending)
          .update_all(downstream_completed_at: completed_at, updated_at: completed_at)
        @item.update!(last_downstream_at: completed_at)
      end
    end
  rescue StandardError
    DebugLogEntry.capture(category: "provider_sync", level: "error",
      message: "FinanceKit downstream scheduling failed", source: self.class.name,
      provider_key: "financekit", family: @item.family,
      metadata: { financekit_item_id: @item.id, batches: @batch_ids.size })
  end

  private

    def with_publisher_claim
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", advisory_lock_key ])
      )
      # Another worker holds this publisher's downstream work. It completes the
      # batches it claimed, and the sweep picks up anything left behind.
      return unless acquired

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", advisory_lock_key ])
        )
      end
    end

    def advisory_lock_key
      # Matches the keying used by the other advisory-locked jobs in this app.
      @advisory_lock_key ||= Digest::MD5.hexdigest("#{ADVISORY_LOCK_SCOPE}:#{@item.id}").to_i(16) % (2**62)
    end
end
