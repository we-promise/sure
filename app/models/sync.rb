class Sync < ApplicationRecord
  # We run a cron that marks any syncs that have not been resolved in 24 hours as "stale"
  # Syncs often become stale when new code is deployed and the worker restarts
  STALE_AFTER = 24.hours

  # The max time that a sync will show in the UI (after 5 minutes)
  VISIBLE_FOR = 5.minutes

  include AASM

  Error = Class.new(StandardError)

  belongs_to :syncable, polymorphic: true

  belongs_to :parent, class_name: "Sync", optional: true
  has_many :children, class_name: "Sync", foreign_key: :parent_id, dependent: :destroy

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :incomplete, -> { where("syncs.status IN (?)", %w[pending syncing]) }
  # Cancel-requested syncs are excluded so spinners clear immediately and
  # sync_later stops piggybacking new requests onto a dying sync.
  scope :visible, -> { incomplete.where("syncs.created_at > ?", VISIBLE_FOR.ago).where(cancel_requested_at: nil) }

  after_commit :update_family_sync_timestamp, on: [ :create, :update ]

  serialize :sync_stats, coder: JSON

  validate :window_valid

  # Sync state machine
  aasm column: :status, timestamps: true do
    state :pending, initial: true
    state :syncing
    state :completed
    state :failed
    state :stale

    after_all_transitions :handle_transition

    event :start, after_commit: :handle_start_transition do
      transitions from: :pending, to: :syncing
    end

    event :complete, after_commit: :handle_completion_transition do
      transitions from: :syncing, to: :completed
    end

    event :fail do
      transitions from: :syncing, to: :failed
    end

    # Marks a sync that never completed within the expected time window
    event :mark_stale do
      transitions from: %i[pending syncing], to: :stale
    end
  end

  class << self
    def clean
      incomplete.where("syncs.created_at < ?", STALE_AFTER.ago).find_each(&:mark_stale!)
    end

    def for_family(family, resource_owner: nil)
      query = where(syncable_type: "Family", syncable_id: family.id)
      query = query.or(where(syncable_type: "Account", syncable_id: account_syncable_ids(family, resource_owner)))

      family_syncable_associations.each do |association|
        query = query.or(
          where(syncable_type: association.klass.name, syncable_id: family.public_send(association.name).select(:id))
        )
      end

      query
    end

    # True iff the family has any pending/syncing Sync — across its own row,
    # its accounts, and every Syncable provider `*_items` association. Built
    # on `for_family` so new provider integrations are picked up automatically
    # via `family_syncable_associations` reflection (no hand-rolled list).
    def any_incomplete_for?(family)
      for_family(family).incomplete.exists?
    end

    private
      def account_syncable_ids(family, resource_owner)
        (resource_owner ? resource_owner.accessible_accounts : family.accounts)
          .where(family_id: family.id)
          .select(:id)
      end

      def family_syncable_associations
        Family.reflect_on_all_associations(:has_many).select do |association|
          association.name.to_s.end_with?("_items") &&
            association.klass.included_modules.include?(Syncable)
        rescue NameError
          false
        end
      end
  end

  def in_progress?
    pending? || syncing?
  end

  def terminal?
    completed? || failed? || stale?
  end

  def api_error_payload
    return unless failed? || stale?
    return if stale? && error.blank?

    {
      message: stale? ? "Sync became stale before completion" : "Sync failed"
    }
  end

  def perform
    Rails.logger.tagged("Sync", id, syncable_type, syncable_id) do
      # This can happen on server restarts or if Sidekiq enqueues a duplicate job
      unless may_start?
        Rails.logger.warn("Sync #{id} is not in a valid state (#{aasm.from_state}) to start.  Skipping sync.")
        return
      end

      # Guard: syncable may have been deleted while job was queued
      unless syncable.present?
        Rails.logger.warn("Sync #{id} - syncable #{syncable_type}##{syncable_id} no longer exists. Marking as failed.")
        start! if may_start?
        fail! if may_fail?
        update(error: "Syncable record was deleted")
        return
      end

      # Guard: syncable may be scheduled for deletion
      if syncable.respond_to?(:scheduled_for_deletion?) && syncable.scheduled_for_deletion?
        Rails.logger.warn("Sync #{id} - syncable #{syncable_type}##{syncable_id} is scheduled for deletion. Skipping sync.")
        start! if may_start?
        fail! if may_fail?
        update(error: "Syncable record is scheduled for deletion")
        return
      end

      start!

      begin
        syncable.perform_sync(self)
      rescue => e
        # Re-check state under a row lock (with_lock reloads): the sync may
        # have been terminalized externally (marked stale by SyncCleanerJob)
        # while this job was still running. An unguarded fail! on the in-memory
        # record would silently overwrite that terminal status.
        with_lock { fail! if may_fail? }
        update(error: e.message)
        report_error(e)
      ensure
        finalize_if_all_children_finalized
      end
    end
  end

  # Requests cooperative cancellation of this sync tree. Only this sync
  # carries the flag: pending descendants are marked stale immediately (their
  # queued jobs no-op via the may_start? guard), while descendants whose jobs
  # are already running finish their work honestly — finalization then
  # resolves this sync to stale instead of completed. Returns false when the
  # sync is already terminal.
  def request_cancel!
    result = with_lock do
      if pending?
        # Job hasn't started — safe to resolve immediately; the queued job
        # will no-op via the may_start? guard.
        update!(cancel_requested_at: Time.current)
        mark_stale!
        :cancelled_before_start
      elsif syncing?
        update!(cancel_requested_at: Time.current)
        :cancel_requested
      end
    end
    return false if result.nil?

    if result == :cancel_requested
      cancel_pending_descendants!
      finalize_if_all_children_finalized
    end

    true
  end

  # Fresh DB read — cancellation is requested from the web process while this
  # sync's job holds a stale in-memory copy of the record.
  def cancel_requested?
    self.class.where(id: id).pick(:cancel_requested_at).present?
  end

  # Finalizes the current sync AND parent (if it exists)
  def finalize_if_all_children_finalized
    Sync.transaction do
      lock!

      # If this is the "parent" and there are still children running, don't finalize.
      return unless all_children_finalized?

      if syncing?
        if cancel_requested_at?
          # User asked for cancellation while work was in flight. Whatever
          # children completed keep their data; the tree resolves to stale
          # (which also skips post-sync below).
          mark_stale!
        elsif has_failed_children?
          fail!
        else
          complete!
        end
      end

      # If we make it here, the sync is finalized.  Run post-sync, regardless of failure/success —
      # unless the sync was terminalized externally (marked stale by SyncCleanerJob while its job
      # was still running). A stale sync's job has been written off: re-running transfer matching,
      # rules, and broadcasts for it would apply side effects for work the system already abandoned.
      perform_post_sync unless stale?
    end

    # If this sync has a parent, try to finalize it so the child status propagates up the chain.
    parent&.finalize_if_all_children_finalized
  end

  # If a sync is pending, we can adjust the window if new syncs are created with a wider window.
  def expand_window_if_needed(new_window_start_date, new_window_end_date)
    return unless pending?
    return if self.window_start_date.nil? && self.window_end_date.nil? # already as wide as possible

    earliest_start_date = if self.window_start_date && new_window_start_date
      [ self.window_start_date, new_window_start_date ].min
    else
      nil
    end

    latest_end_date = if self.window_end_date && new_window_end_date
      [ self.window_end_date, new_window_end_date ].max
    else
      nil
    end

    update(
      window_start_date: earliest_start_date,
      window_end_date: latest_end_date
    )
  end

  protected
    def cancel_pending_descendants!
      children.incomplete.find_each do |child|
        child.with_lock { child.mark_stale! if child.pending? }
        child.cancel_pending_descendants!
      end
    end

  private
    def log_status_change
      Rails.logger.info("changing from #{aasm.from_state} to #{aasm.to_state} (event: #{aasm.current_event})")
    end

    def has_failed_children?
      children.failed.any?
    end

    def all_children_finalized?
      children.incomplete.empty?
    end

    def perform_post_sync
      Rails.logger.info("Performing post-sync for #{syncable_type} (#{syncable.id})")
      syncable.perform_post_sync
      syncable.broadcast_sync_complete
    rescue => e
      Rails.logger.error("Error performing post-sync for #{syncable_type} (#{syncable.id}): #{e.message}")
      report_error(e)
    end

    def report_error(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(sync_id: id)
      end
    end

    def report_warnings
      todays_sync_count = syncable.syncs.where(created_at: Date.current.all_day).count

      if todays_sync_count > 10
        Sentry.capture_exception(
          Error.new("#{syncable_type} (#{syncable.id}) has exceeded 10 syncs today (count: #{todays_sync_count})"),
          level: :warning
        )
      end
    end

    def handle_start_transition
      report_warnings
    end

    def handle_transition
      log_status_change
    end

    def handle_completion_transition
      family.touch(:latest_sync_completed_at)
    end

    def window_valid
      if window_start_date && window_end_date && window_start_date > window_end_date
        errors.add(:window_end_date, "must be greater than window_start_date")
      end
    end

    def update_family_sync_timestamp
      return if syncable.nil?
      return unless family&.persisted?

      family.touch(:latest_sync_activity_at)
    end

    def family
      return nil unless syncable

      if syncable.is_a?(Family)
        syncable
      else
        syncable.family
      end
    end
end
