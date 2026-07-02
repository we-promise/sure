module Syncable
  extend ActiveSupport::Concern

  included do
    has_many :syncs, as: :syncable, dependent: :destroy
  end

  def syncing?
    # Avoid a query when the syncs association was eager-loaded (e.g. the
    # accounts index loads every provider item with includes(:syncs) and
    # renders sync status per item).
    return syncs.any?(&:visible?) if syncs.loaded?

    syncs.visible.any?
  end

  # Schedules a sync for syncable.  If there is an existing sync pending/syncing for this syncable,
  # we do not create a new sync, and attempt to expand the sync window if needed.
  #
  # NOTE: Uses `visible` scope (syncs < 5 min old) instead of `incomplete` to prevent
  # getting stuck on stale syncs after server/Sidekiq restarts. If a sync is older than
  # 5 minutes, we assume its job was lost and create a new sync.
  def sync_later(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    Sync.transaction do
      with_lock do
        sync = self.syncs.visible.first

        if sync
          Rails.logger.info("There is an existing recent sync, expanding window if needed (#{sync.id})")
          sync.expand_window_if_needed(window_start_date, window_end_date)

          # Update parent relationship if one is provided and sync doesn't already have a parent
          if parent_sync && !sync.parent_id
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
    latest_sync&.error || latest_sync&.children&.map(&:error)&.compact&.first
  end

  def last_synced_at
    latest_completed_sync&.completed_at
  end

  def last_sync_created_at
    latest_sync&.created_at
  end

  # Public so views/models can reuse one lookup instead of re-querying
  # syncs.ordered.first per status method. Uses the eager-loaded association
  # when available (provider item lists render several statuses per item).
  def latest_sync
    if syncs.loaded?
      syncs.max_by { |s| [ s.created_at, s.id ] }
    else
      syncs.ordered.first
    end
  end

  def latest_completed_sync
    if syncs.loaded?
      syncs.select(&:completed?).max_by { |s| [ s.created_at, s.id ] }
    else
      syncs.completed.ordered.first
    end
  end

  private
    def syncer
      self.class::Syncer.new(self)
    end

    def sync_broadcaster
      self.class::SyncCompleteEvent.new(self)
    end
end
