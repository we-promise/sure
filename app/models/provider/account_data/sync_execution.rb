# A live execution is distinct from a logical Sync and its data-fetch attempt.
# Taking over an expired worker changes this revision and the connection epoch,
# while retaining batch keys, generation identities and observation windows.
class Provider::AccountData::SyncExecution
  LEASE_DURATION = 10.minutes
  RECOVERY_LIMIT = 100

  attr_reader :connection, :sync, :revision, :writer_epoch, :lease_owner

  def initialize(sync)
    unless sync.persisted? && sync.syncable_type == "ProviderConnection"
      raise ArgumentError, "Provider execution requires a persisted connection Sync"
    end
    @sync = sync
    @connection = sync.syncable
  end

  def perform
    outcome = admit
    if outcome == :run
      yield self
    elsif outcome == :finalize_only
      finalize_completed_work!
    elsif outcome == :stale
      sync.finalize_if_all_children_finalized
    end
  ensure
    release if @acquired
  end

  def fenced
    connection.with_lock do
      sync.lock!
      assert_current!
      result = yield
      connection.update!(lease_expires_at: LEASE_DURATION.from_now)
      result
    end
  end

  # Call under the connection lock; RequestGrant also holds its ordered Sync
  # lock before invoking this check. This capability never recaptures a token.
  def assert_current!(connection: @connection, current_sync: nil)
    current_sync ||= Sync.find_by(id: sync.id)
    unless connection.id == @connection.id && owned?(connection: connection, current_sync: current_sync) && eligible?(connection) &&
        !current_sync.send(:continuation_cancelled?) && current_sync.created_at + Sync::STALE_AFTER > Time.current
      raise Provider::AccountData::StaleWriter, "Provider execution no longer owns this sync"
    end
    true
  end

  # Failure and deferral may settle a cancelled or newly disabled connection,
  # but only the original live worker may change the Sync's execution state.
  def transition
    connection.with_lock do
      sync.lock!
      return false unless owned?
      yield
      true
    end
  end

  def finish_work!
    transition { sync.update!(provider_work_finished_at: Time.current, resume_at: nil) }
  end

  def finalize!
    connection.with_lock do
      sync.lock!
      return false unless owned?(allow_terminal: true)
      sync.finalize_if_all_children_finalized
      true
    end
  end

  # Scheduling a duplicate is harmless: admission makes a live lease exclusive.
  # The existing cleaner owns cadence; this does not add a separate scheduler.
  def self.recover_stalled!
    expired = ProviderConnection.where.not(lease_sync_id: nil).where("lease_expires_at <= ?", Time.current).select(:lease_sync_id)
    base = Sync.where(syncable_type: "ProviderConnection", syncable_id: ProviderConnection.select(:id))
      .where("created_at > ?", Sync::STALE_AFTER.ago)
    interrupted = base.where(status: "syncing", provider_work_finished_at: nil, id: expired)
    waiting_parents = Sync.incomplete.where.not(parent_id: nil).select(:parent_id)
    finalizable = base.where.not(id: waiting_parents).where(post_sync_completed_at: nil)
      .where("provider_work_finished_at IS NOT NULL OR (status IN ('failed', 'completed') AND provider_execution_revision > 0)")
      .where(status: %w[syncing failed completed])
    scope = interrupted.or(finalizable)
    scope.order(:created_at, :id).limit(RECOVERY_LIMIT).each { |sync| SyncJob.perform_later(sync) }
  end

  # Old worker cleanup must use the same lock order as execution admission.
  def self.expire!(sync)
    connection = ProviderConnection.find_by(id: sync.syncable_id)
    return new(sync).send(:settle_missing_owner!, stale: true) unless connection
    expired = false
    begin
      connection.with_lock do
        sync.lock!
        if sync.in_progress? && sync.created_at <= Sync::STALE_AFTER.ago
          sync.provider_execution_revision += 1
          sync.mark_stale!
          if connection.lease_sync_id == sync.id
            connection.update!(writer_epoch: connection.writer_epoch + 1, lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          end
          expired = true
        end
      end
    rescue ActiveRecord::RecordNotFound => error
      execution = new(sync)
      if execution.send(:missing_record?, error, ProviderConnection, connection.id)
        return execution.send(:settle_missing_owner!, stale: true)
      elsif execution.send(:missing_record?, error, Sync, sync.id)
        return
      else
        raise
      end
    end
    sync.finalize_if_all_children_finalized if expired
  end

  private
    def admit
      return settle_missing_owner! unless connection
      admit_existing_owner
    end

    def admit_existing_owner
      connection.with_lock do
        sync.lock!
        # Finishing already dispatched work is not another provider execution.
        # In particular, its child input proofs retain the original writer epoch.
        return :finalize_only if !sync.stale? && (sync.provider_work_finished_at || sync.terminal?)
        return if sync.terminal?
        if sync.send(:continuation_cancelled?) || sync.created_at <= Sync::STALE_AFTER.ago || !eligible?(connection)
          sync.provider_execution_revision += 1
          sync.mark_stale!
          if connection.lease_sync_id == sync.id
            connection.update!(writer_epoch: connection.writer_epoch + 1, lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          end
          return :stale
        end
        return if sync.pending? && ((sync.resume_at && sync.resume_at > Time.current) || (sync.predecessor && !sync.predecessor.terminal?))

        active_lease = connection.lease_expires_at && connection.lease_expires_at > Time.current
        if active_lease
          defer_pending if sync.pending?
          return
        end
        if sync.syncing?
          unless connection.lease_sync_id == sync.id && connection.lease_owner && connection.lease_expires_at
            # Older, unbound executions need explicit recovery; absence of a
            # lease is not evidence that this worker owns their partial work.
            return
          end
        elsif connection.lease_sync_id && connection.lease_sync_id != sync.id &&
            Sync.where(id: connection.lease_sync_id, status: %w[pending syncing]).exists?
          defer_pending
          return
        end

        @revision = sync.provider_execution_revision + 1
        @writer_epoch = connection.writer_epoch + 1
        @lease_owner = SecureRandom.uuid
        sync.provider_execution_revision = revision
        if sync.pending?
          sync.provider_work_finished_at = nil
          sync.start!
        else
          sync.save!
        end
        connection.update!(writer_epoch: writer_epoch, lease_sync_id: sync.id,
          lease_owner: lease_owner, lease_expires_at: LEASE_DURATION.from_now)
        @acquired = true
        :run
      end
    rescue ActiveRecord::RecordNotFound => error
      # lock! reloads its receiver, so a cached connection or queued Sync may
      # disappear before admission. Do not reinterpret failures from any other
      # lookup as proof that this execution's owner was deleted.
      if missing_record?(error, ProviderConnection, connection&.id || sync.syncable_id)
        settle_missing_owner!
      elsif missing_record?(error, Sync, sync.id)
        nil
      else
        raise
      end
    end

    def missing_record?(error, model, id)
      error.model == model.name && (error.id.nil? || error.id.to_s == id.to_s) && !model.exists?(id: id)
    end

    def settle_missing_owner!(stale: false)
      expected_owner_id = connection&.id || sync.syncable_id
      parent_id = nil
      Sync.transaction(requires_new: true) do
        current = Sync.where(id: sync.id).lock.first
        return unless current && current.syncable_type == "ProviderConnection" && current.syncable_id == expected_owner_id
        return if ProviderConnection.exists?(id: expected_owner_id) || !current.in_progress?
        return if stale && current.created_at > Sync::STALE_AFTER.ago

        now = Time.current
        attributes = { status: stale ? "stale" : "failed", error: "Syncable record was deleted",
          provider_execution_revision: current.provider_execution_revision + 1, updated_at: now }
        attributes[:failed_at] = current.failed_at || now unless stale
        # The owner is absent, so normal presence validation and owner callbacks
        # cannot run. This locked settlement performs no provider/post-sync work
        # and does not manufacture either work or post completion markers.
        raise Provider::AccountData::StaleWriter, "Missing-owner sync settlement changed" unless current.update_columns(attributes)
        parent_id = current.parent_id
      end
      Sync.find_by(id: parent_id)&.finalize_if_all_children_finalized if parent_id
      nil
    end

    def defer_pending
      retry_at = 15.seconds.from_now
      retry_at = [ connection.lease_expires_at, retry_at ].min if connection.lease_expires_at && connection.lease_expires_at > Time.current
      sync.start!
      sync.send(:schedule_provider_continuation, Provider::AccountData::DeferredPage.new(
        resume_at: retry_at))
    end

    def finalize_completed_work!
      connection.with_lock do
        sync.lock!
        return if sync.stale? || !(sync.terminal? || sync.provider_work_finished_at)
        sync.finalize_if_all_children_finalized
      end
    end

    def eligible?(current)
      control = ProviderMigrationControl.find_by(provider_connection_id: current.id)
      current.good? && !current.scheduled_for_deletion? && (control.nil? || control.native_owned?)
    end

    def owned?(connection: @connection, allow_terminal: false, current_sync: nil)
      current = current_sync || Sync.find_by(id: sync.id)
      current && current.id == sync.id && current.syncable_type == "ProviderConnection" && current.syncable_id == connection.id &&
        (current.syncing? || (allow_terminal && current.terminal?)) &&
        current.provider_execution_revision == revision && connection.writer_epoch == writer_epoch &&
        connection.lease_sync_id == sync.id && connection.lease_owner == lease_owner &&
        connection.lease_expires_at && connection.lease_expires_at > Time.current
    end

    def release
      current = ProviderConnection.find_by(id: connection.id)
      return unless current
      current.with_lock do
        sync.lock!
        if current.lease_owner == lease_owner && current.writer_epoch == writer_epoch && current.lease_sync_id == sync.id &&
            sync.provider_execution_revision == revision && (!sync.syncing? || sync.provider_work_finished_at)
          current.update!(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
        end
      end
    end
end
