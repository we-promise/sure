module Syncable
  extend ActiveSupport::Concern

  included do
    has_many :syncs, as: :syncable, dependent: :destroy
  end

  def syncing?
    if Current.respond_to?(:syncing_by_syncable) && (syncing_by_syncable = Current.syncing_by_syncable)
      key = [ self.class.base_class.name, id ]
      return !!syncing_by_syncable[key] if syncing_by_syncable.key?(key)
    end

    if association(:syncs).loaded?
      syncs.any?(&:visible?)
    else
      syncs.visible.any?
    end
  end

  def latest_sync_record
    if Current.respond_to?(:latest_sync_by_syncable) && (latest_sync_by_syncable = Current.latest_sync_by_syncable)
      key = [ self.class.base_class.name, id ]
      return latest_sync_by_syncable[key] if latest_sync_by_syncable.key?(key)
    end

    if association(:syncs).loaded?
      syncs.max_by { |sync| [ sync.created_at, sync.id ] }
    else
      syncs.ordered.first
    end
  end

  def latest_completed_sync_record
    if Current.respond_to?(:latest_completed_sync_by_syncable) && (latest_completed_sync_by_syncable = Current.latest_completed_sync_by_syncable)
      key = [ self.class.base_class.name, id ]
      return latest_completed_sync_by_syncable[key] if latest_completed_sync_by_syncable.key?(key)
    end

    if association(:syncs).loaded?
      syncs.select(&:completed?).max_by { |sync| [ sync.created_at, sync.id ] }
    else
      syncs.completed.ordered.first
    end
  end

  # Schedules a sync for syncable. If there is an existing pending sync, widen
  # its window. If work is already running, queue a follow-up to run afterward
  # so it can use data committed during the active sync.
  #
  # NOTE: Uses `visible` scope (syncs < 5 min old) instead of `incomplete` to prevent
  # getting stuck on stale syncs after server/Sidekiq restarts. If a sync is older than
  # 5 minutes, we assume its job was lost and create a new sync.
  def sync_later(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    Sync.transaction do
      with_lock do
        # Prefer a queued sync over one already running. Queued follow-up syncs
        # can still have their requested window widened; a running sync cannot.
        sync = self.syncs.visible.where(status: "pending").ordered.first
        sync ||= self.syncs.where(status: "syncing").ordered.first

        if sync
          if sync.pending?
            Rails.logger.info("There is an existing pending sync, expanding window if needed (#{sync.id})")
            sync.expand_window_if_needed(window_start_date, window_end_date)
          else
            # A running sync may already have read the ledger and chosen its
            # incremental starting balance. Queue a serialized follow-up so a
            # mutation made during that sync is recalculated against fresh
            # entries after it finishes.
            Rails.logger.info("There is an existing running sync, queueing a follow-up (#{sync.id})")
            sync = self.syncs.create!(
              parent: parent_sync || sync.parent,
              wait_for_sync: sync,
              window_start_date: window_start_date,
              window_end_date: window_end_date
            )

            SyncJob.perform_later(sync)
          end

          # Update parent relationship if one is provided and sync doesn't already have a parent
          if parent_sync && !sync.parent_id && sync.pending?
            sync.update!(parent: parent_sync)
          end
        else
          sync = self.syncs.create!(
            parent: parent_sync,
            window_start_date: window_start_date,
            window_end_date: window_end_date
          )

          SyncJob.perform_later(sync)
        end

        sync
      end
    end
  end

  def perform_sync(sync)
    syncer.perform_sync(sync)
  end

  def perform_post_sync
    syncer.perform_post_sync
  end

  def broadcast_sync_complete
    sync_broadcaster.broadcast
  end

  def sync_error
    latest_sync_record&.error || latest_sync_record&.children&.map(&:error)&.compact&.first
  end

  def last_synced_at
    latest_completed_sync_record&.completed_at
  end

  def last_sync_created_at
    latest_sync_record&.created_at
  end

  private
    def latest_sync
      latest_sync_record
    end

    def latest_completed_sync
      latest_completed_sync_record
    end

    def syncer
      self.class::Syncer.new(self)
    end

    def sync_broadcaster
      self.class::SyncCompleteEvent.new(self)
    end
end
