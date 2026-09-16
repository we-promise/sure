class Sync < ApplicationRecord
  # We run a cron that marks any syncs that have not been resolved in 24 hours as "stale"
  # Syncs often become stale when new code is deployed and the worker restarts
  STALE_AFTER = 24.hours

  # The max time that a sync will show in the UI (after 5 minutes)
  VISIBLE_FOR = 5.minutes

  include AASM

  Error = Class.new(StandardError)

  belongs_to :syncable, polymorphic: true
  belongs_to :account_family, class_name: "Family", optional: true

  belongs_to :parent, class_name: "Sync", optional: true
  has_many :children, class_name: "Sync", foreign_key: :parent_id, dependent: :destroy
  belongs_to :predecessor, class_name: "Sync", optional: true
  # The predecessor FK restricts successors to the same owner. Remove their
  # queued work with its context; ingestion evidence still restricts deletion.
  has_many :successors, class_name: "Sync", foreign_key: :predecessor_id, dependent: :destroy
  # Immutable evidence can only be deleted by the owning Sync FK cascade.
  has_many :account_sync_inputs, class_name: "Account::SyncInput"
  has_one :account_sync_preparation, class_name: "Account::SyncPreparation"
  attr_readonly :predecessor_id
  attr_readonly :account_family_id

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :incomplete, -> { where("syncs.status IN (?)", %w[pending syncing]) }
  # Cancel-requested syncs are excluded so spinners clear immediately and
  # sync_later stops piggybacking new requests onto a dying sync.
  scope :visible, -> { incomplete.where("syncs.created_at > ?", VISIBLE_FOR.ago).where(cancel_requested_at: nil) }
  scope :awaiting_provider, -> { incomplete.where.not(resume_at: nil).where(cancel_requested_at: nil).where("syncs.created_at > ?", STALE_AFTER.ago) }

  after_commit :update_family_sync_timestamp, on: [ :create, :update ]
  # A transition may be followed by an error/stats save in the same transaction,
  # replacing saved_changes. Re-enqueueing pending successors is idempotent;
  # relying on the final save's status diff can strand them permanently.
  after_update_commit :enqueue_ready_successors, if: -> { (provider_sync? || account_sync?) && terminal? }

  serialize :sync_stats, coder: JSON

  validate :window_valid
  validate :predecessor_ownership
  before_validation :capture_account_family, on: :create
  validate :account_family_scope
  validates :provider_attempt, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :provider_execution_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  attr_reader :provider_execution
  validates :predecessor_id, uniqueness: { conditions: -> { incomplete.where(cancel_requested_at: nil) } },
    allow_nil: true, if: -> { in_progress? && cancel_requested_at.nil? }

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

    event :defer_provider do
      transitions from: :syncing, to: :pending, guard: :provider_sync?
    end

    # Marks a sync that never completed within the expected time window
    event :mark_stale do
      transitions from: %i[pending syncing], to: :stale
    end
  end

  class << self
    def clean
      incomplete.where.not(syncable_type: %w[ProviderConnection Account]).where("syncs.created_at < ?", STALE_AFTER.ago).find_each(&:mark_stale!)
      incomplete.where(syncable_type: "Account").where("syncs.created_at < ?", STALE_AFTER.ago).find_each do |sync|
        expire_account(sync)
      end
      incomplete.where(syncable_type: "ProviderConnection").where("syncs.created_at <= ?", STALE_AFTER.ago)
        .find_each { |sync| Provider::AccountData::SyncExecution.expire!(sync) }
    end

    def for_family(family, resource_owner: nil)
      return none if resource_owner && resource_owner.family_id != family.id

      query = where(syncable_type: "Family", syncable_id: family.id)
      accounts = where(syncable_type: "Account", account_family_id: family.id)
      # Retained family ownership does not confer user access to an account.
      # Retired accounts have no retained owner/share ACL in this interface.
      accounts = accounts.where(syncable_id: account_syncable_ids(family, resource_owner)) if resource_owner
      query = query.or(accounts)

      providers = Family::ProviderSyncables.new(family)
      providers.history_scopes.each do |scope|
        query = query.or(
          where(syncable_type: scope.klass.base_class.name, syncable_id: scope.select(:id))
        )
      end

      retained = providers.retained_history_scope.select(:legacy_type, :legacy_id)
      query = query.or(where("(syncs.syncable_type, syncs.syncable_id) IN (#{retained.to_sql})"))

      query
    end

    def for_syncables(syncables)
      syncables = Array(syncables).compact
      return none if syncables.empty?

      scope = none
      syncables.group_by do |record|
        type = record.class.base_class.name
        [ type, type == "Account" ? record.family_id : nil ]
      end.each do |(type, family_id), records|
        ids = records.map(&:id)
        owners = where(syncable_type: type, syncable_id: ids)
        owners = owners.where(account_family_id: family_id) if type == "Account"
        scope = scope.or(owners)
      end
      scope
    end

    def latest_by_syncable(syncables)
      keyed_syncables = syncable_keys(syncables)
      return {} if keyed_syncables.empty?

      latest = for_syncables(syncables)
        .select("DISTINCT ON (syncable_type, syncable_id) syncs.*")
        .order("syncable_type, syncable_id, created_at DESC, id DESC")
        .includes(:children)
        .index_by { |sync| [ sync.syncable_type, sync.syncable_id ] }

      keyed_syncables.index_with { |key| latest[key] }
    end

    def latest_completed_by_syncable(syncables)
      keyed_syncables = syncable_keys(syncables)
      return {} if keyed_syncables.empty?

      latest = for_syncables(syncables)
        .completed
        .select("DISTINCT ON (syncable_type, syncable_id) syncs.*")
        .order("syncable_type, syncable_id, created_at DESC, id DESC")
        .index_by { |sync| [ sync.syncable_type, sync.syncable_id ] }

      keyed_syncables.index_with { |key| latest[key] }
    end

    def syncing_by_syncable(syncables)
      keyed_syncables = syncable_keys(syncables)
      return {} if keyed_syncables.empty?

      syncing_keys = for_syncables(syncables)
        .visible
        .distinct
        .pluck(:syncable_type, :syncable_id)
        .to_set

      keyed_syncables.index_with { |key| syncing_keys.include?(key) }
    end

    # True iff the family has any pending/syncing Sync — across its own row,
    # its accounts, legacy provider items and shared provider connections.
    # History remains visible even when a connection is no longer scheduled.
    def any_incomplete_for?(family)
      history = for_family(family).incomplete
      history.where.not(syncable_type: "Account").or(
        history.where(syncable_type: "Account", syncable_id: available_account_ids(family))
      ).exists?
    end

    private
      def expire_account(sync)
        original_owner = [ sync.syncable_type, sync.syncable_id, sync.account_family_id ]
        transaction(requires_new: true) do
          if sync.account_family_id
            owner = Account::SyncAdmission.current(account_id: sync.syncable_id, family_id: sync.account_family_id, lock: true)
          end
          sync.lock!
          unless [ sync.syncable_type, sync.syncable_id, sync.account_family_id ] == original_owner
            raise Provider::AccountData::StaleWriter, "Sync owner changed before expiration"
          end
          next unless sync.in_progress? && sync.created_at < STALE_AFTER.ago

          owner ? sync.mark_stale! : sync.stop_unavailable_account!
        end
      rescue ActiveRecord::LockWaitTimeout
        # An admitted owner is changing. The next sweep rechecks the same row.
        nil
      end

      def syncable_keys(syncables)
        Array(syncables).compact.uniq { |record| [ record.class.base_class.name, record.id ] }
          .map { |record| [ record.class.base_class.name, record.id ] }
      end

      def account_syncable_ids(family, resource_owner)
        resource_owner.accessible_accounts.where(family_id: family.id).select(:id)
      end

      def available_account_ids(family)
        Account.where(family_id: family.id, status: Account::SyncAdmission::SUPPORTED_STATES)
          .where(<<~SQL.squish).select(:id)
            NOT EXISTS (
              SELECT 1 FROM account_ingestion_identities identity_row
              WHERE identity_row.id = accounts.id AND
                (identity_row.retired_at IS NOT NULL OR identity_row.family_id <> accounts.family_id OR
                 identity_row.live_account_id IS DISTINCT FROM accounts.id)
            )
          SQL
      end

  end

  def in_progress?
    pending? || syncing?
  end

  # Mirrors the `visible` scope for in-memory checks on preloaded syncs.
  def visible?
    in_progress? && created_at > VISIBLE_FOR.ago
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
    if account_sync?
      Account::SyncExecution.with(self) { |owner| perform_work(account_owner: owner) }
    elsif provider_sync?
      Provider::AccountData::SyncExecution.new(self).perform do |execution|
        @provider_execution = execution
        begin
          perform_work(provider_execution: execution)
        ensure
          @provider_execution = nil
        end
      end
    else
      perform_work
    end
  end

  def verify_account_inputs!
    inputs = account_sync_inputs.order(:resource).to_a
    unless account_sync? && account_inputs_sealed_at && account_inputs_digest == Account::SyncInput.digest(inputs)
      raise Provider::AccountData::InvalidResponse, "Account execution inputs are missing or changed"
    end
    inputs
  end

  def retry_account_later
    unless account_sync? && account_family_id
      raise Account::SyncAdmission::Unavailable, "Financial account is unavailable for synchronization"
    end
    owner = Account::SyncAdmission.fetch!(account_id: syncable_id, family_id: account_family_id)
    Account::SyncQueue.new(owner).enqueue(parent_sync: nil, window_start_date: window_start_date,
      window_end_date: window_end_date, retry_of: self)
  end

  # The caller holds the Sync row lock and has freshly rejected its Account.
  # No AASM start/completion or after-commit callback may dispatch more work for
  # that missing/retired/deleting owner. Existing terminal history is unchanged.
  def stop_unavailable_account!
    raise ArgumentError, "Expected an account execution" unless account_sync?
    return false unless in_progress?
    update_columns(status: "stale", updated_at: Time.current,
      error: "Account is unavailable for sync")
    DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
      message: "Account sync stopped because its owner is unavailable", source: self.class.name,
      family_id: account_family_id, account_id: syncable_id,
      metadata: { sync_id: id, account_id: syncable_id })
    true
  end

  def perform_work(provider_execution: nil, account_owner: nil)
    Rails.logger.tagged("Sync", id, syncable_type, syncable_id) do
      if provider_execution
        target = provider_execution.connection
      else
        association(:syncable).target = account_owner if account_owner
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

        target = syncable
        started = with_lock do
          if may_start? && account_sync? && continuation_cancelled?
            mark_stale!
            :cancelled
          elsif may_start? && (!resume_at || resume_at <= Time.current) && (!predecessor || predecessor.terminal?)
            start!
            true
          end
        end
        if started == :cancelled
          finalize_if_all_children_finalized
          return
        end
        return unless started
      end
      provider_work_returned = false

      begin
        target.perform_sync(self)
        provider_work_returned = true
      rescue Provider::AccountData::DeferredPage => e
        if provider_execution
          provider_execution.transition { schedule_provider_continuation(e) }
        else
          schedule_provider_continuation(e)
        end
      rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged => e
        # A rejected legacy dispatch must not run post-sync repair code. That
        # code can itself write financial entries even after the main sync fails.
        mark_fenced = lambda do
          with_lock do
            if may_mark_stale?
              mark_stale!
              update!(error: "Legacy provider execution was fenced")
            end
          end
        end
        settled = if provider_execution
          provider_execution.transition(&mark_fenced)
        else
          mark_fenced.call
          true
        end
        if settled
          manifest = Provider::AccountData::MigrationManifest.all.find { |entry| entry.item_type == target.class.base_class.name }
          DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Legacy provider execution was fenced",
            source: self.class.name, provider_key: manifest&.provider_key, family: family,
            metadata: { sync_id: id, syncable_type: syncable_type, syncable_id: syncable_id, error_class: e.class.name })
        end
      rescue => e
        # Re-check state under a row lock (with_lock reloads): the sync may
        # have been terminalized externally (marked stale by SyncCleanerJob)
        # while this job was still running. An unguarded fail! on the in-memory
        # record would silently overwrite that terminal status.
        if account_sync? && e.is_a?(Account::SyncAdmission::Unavailable)
          with_lock { stop_unavailable_account! }
        elsif provider_execution
          settled = provider_execution.transition do
            continuation_cancelled? ? mark_stale! : fail!
            update!(error: e.message)
          end
          report_error(e) if settled
        else
          with_lock { fail! if may_fail? }
          update(error: e.message)
          report_error(e)
        end
      ensure
        if provider_execution
          provider_execution.finish_work! if provider_work_returned
          provider_execution.finalize!
        end
        finalize_if_all_children_finalized unless provider_execution
      end
    end
  end

  private :perform_work

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

    # Both paths cascade: a pending sync resolved above went terminal without
    # its job ever running, so nothing else will ever call
    # finalize_if_all_children_finalized for it — without this, a parent
    # waiting on the cancelled child stays syncing until the 24h sweep.
    # finalize_if_all_children_finalized re-reads under lock!, so it safely
    # no-ops on this sync's own branch when already terminal.
    cancel_pending_descendants!
    finalize_if_all_children_finalized

    true
  end

  # Fresh DB read — cancellation is requested from the web process while this
  # sync's job holds a stale in-memory copy of the record.
  def cancel_requested?
    self.class.where(id: id).pick(:cancel_requested_at).present?
  end

  # Finalizes the current sync AND parent (if it exists)
  def finalize_if_all_children_finalized
    # A caller may rescue post-sync failure inside an existing transaction. Keep
    # this finalization atomic there too, so partial database effects roll back.
    Sync.transaction(requires_new: true) do
      original_owner = [ syncable_type, syncable_id, account_family_id ]
      if account_sync? && account_family_id
        owner = Account::SyncAdmission.current(account_id: syncable_id, family_id: account_family_id, lock: true)
      end
      lock!
      unless [ syncable_type, syncable_id, account_family_id ] == original_owner
        raise Provider::AccountData::StaleWriter, "Sync owner changed before finalization"
      end
      if account_sync?
        # A child may be finalized by another worker long after initial
        # admission. Account is locked before this child Sync; release both
        # before propagating to its provider/Family parent below.
        unless owner
          stop_unavailable_account!
          return
        end
        association(:syncable).target = owner
      end

      # A deferred provider attempt has not finished its own work. An account
      # child may complete while the provider is waiting or still fanning out.
      return if pending?
      return if provider_sync? && syncing? && provider_work_finished_at.nil?

      # Eagerly load children once so that all_children_finalized? and
      # has_failed_children? can filter in-memory without additional DB queries.
      children.load

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
      unless stale? || post_sync_completed_at
        perform_post_sync
        # Database effects and this marker commit together under the Sync lock.
        # External broadcasts are not transactional and may repeat after a
        # rollback; this is not an exactly-once external delivery guarantee.
        update!(post_sync_completed_at: Time.current)
      end
    end

    # A savepoint does not release an outer transaction's Account locks. Delay
    # upward propagation until commit so provider-parent -> Account queue order
    # is not reversed by Account -> provider-parent finalization.
    if parent_id
      original_parent_id = parent_id
      ActiveRecord.after_all_transactions_commit do
        Sync.find_by(id: original_parent_id)&.finalize_if_all_children_finalized
      end
    end
  end

  # If a sync is pending, we can adjust the window if new syncs are created with a wider window.
  def expand_window_if_needed(new_window_start_date, new_window_end_date)
    return unless pending?
    return if account_inputs_sealed_at
    return if provider_window_frozen?
    return if !provider_sync? && self.window_start_date.nil? && self.window_end_date.nil? # legacy unbounded window

    earliest_start_date = if provider_sync?
      # Native nil starts use configured history or a checkpoint overlap, not
      # unlimited history. A default request must retain an explicit backfill.
      [ self.window_start_date, new_window_start_date ].compact.min
    elsif self.window_start_date && new_window_start_date
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

  def provider_window_frozen?
    provider_sync? && (syncing_at.present? || provider_attempt.positive?)
  end

  def covers_window?(start_date, end_date)
    if provider_sync?
      # Effective starts differ by external account/checkpoint. Without an
      # explicit earlier start we cannot prove a frozen default covers backfill.
      covers_start = start_date.nil? || (window_start_date && window_start_date <= start_date)
      captured_end = [ window_end_date, created_at.utc.to_date ].compact.min
      return covers_start && captured_end >= (end_date || created_at.utc.to_date)
    end
    (window_start_date.nil? || (start_date && window_start_date <= start_date)) &&
      (window_end_date.nil? || (end_date && window_end_date >= end_date))
  end

  protected
    def cancel_pending_descendants!
      children.incomplete.find_each do |child|
        child.with_lock { child.mark_stale! if child.pending? }
        child.cancel_pending_descendants!
      end
    end

  private
    def capture_account_family
      return unless new_record? && account_sync?

      owner = Account::SyncAdmission.current(account_id: syncable_id)
      unless owner && (account_family_id.nil? || account_family_id == owner.family_id)
        errors.add(:account_family, "must identify an available financial account's family")
        return
      end
      self.account_family_id = owner.family_id
    end

    def account_family_scope
      if !account_sync? && account_family_id.present?
        errors.add(:account_family, "is only valid for an account execution")
      end
    end

    def predecessor_ownership
      if predecessor && (!(provider_sync? || account_sync?) || predecessor.syncable_type != syncable_type || predecessor.syncable_id != syncable_id || predecessor.id == id)
        errors.add(:predecessor, "must be an earlier sync of this owner")
      end
    end

    def enqueue_ready_successors
      if account_sync?
        return unless account_family_id && Account::SyncAdmission.current(account_id: syncable_id, family_id: account_family_id)
      end
      successors.pending.where(cancel_requested_at: nil).find_each { |successor| SyncJob.perform_later(successor) }
    end

    def provider_sync?
      syncable_type == "ProviderConnection"
    end

    def account_sync?
      syncable_type == "Account"
    end

    def schedule_provider_continuation(error)
      with_lock do
        return unless syncing?
        if continuation_cancelled?
          mark_stale!
        elsif provider_sync? && error.resume_at.is_a?(Time) && provider_attempt < 1_000 &&
            [ error.resume_at, 1.second.from_now ].max < created_at + STALE_AFTER
          self.resume_at = [ error.resume_at, 1.second.from_now ].max
          self.provider_attempt += 1
          self.provider_work_finished_at = nil
          self.error = nil
          defer_provider!
          # Active Job defers enqueueing until this state transaction commits.
          SyncJob.set(wait_until: resume_at).perform_later(self)
        else
          fail!
          update!(error: "Provider continuation exceeded its retry boundary")
        end
      end
    end

    def continuation_cancelled?
      return true if cancel_requested_at?
      ancestor_id = parent_id
      visited = [ id ]
      while ancestor_id
        return true if visited.include?(ancestor_id) || visited.size >= 100
        visited << ancestor_id
        ancestor = Sync.where(id: ancestor_id).pick(:parent_id, :cancel_requested_at)
        return false unless ancestor
        return true if ancestor.last
        ancestor_id = ancestor.first
      end
      false
    end

    def log_status_change
      Rails.logger.info("changing from #{aasm.from_state} to #{aasm.to_state} (event: #{aasm.current_event})")
    end

    def has_failed_children?
      children.any?(&:failed?)
    end

    def all_children_finalized?
      children.none? { |child| child.pending? || child.syncing? }
    end

    def perform_post_sync
      Rails.logger.info("Performing post-sync for #{syncable_type} (#{syncable.id})")
      syncable.perform_post_sync
      syncable.broadcast_sync_complete
    rescue => e
      Rails.logger.error("Error performing post-sync for #{syncable_type} (#{syncable.id}): #{e.message}")
      report_error(e)
      raise
    end

    def report_error(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(sync_id: id)
      end
    end

    def report_warnings
      return unless syncable
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
      return account_family if account_sync?
      return nil unless syncable

      if syncable.is_a?(Family)
        syncable
      else
        syncable.family
      end
    end
end
