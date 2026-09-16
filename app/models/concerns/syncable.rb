module Syncable
  extend ActiveSupport::Concern

  included do
    sync_owner_keys = name == "Account" ? { foreign_key: [ :syncable_id, :account_family_id ], primary_key: [ :id, :family_id ] } : {}
    has_many :syncs, as: :syncable, dependent: :destroy, **sync_owner_keys
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

  # Schedules a sync for syncable.  If there is an existing sync pending/syncing for this syncable,
  # we do not create a new sync, and attempt to expand the sync window if needed.
  #
  # Legacy/account requests use the five-minute visible window. Shared providers
  # retain one logical run through deferred attempts; wider requests queue a new
  # run after it, and a lost pending job can be requeued without replacing evidence.
  def sync_later(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    if is_a?(Account)
      return Account::SyncQueue.new(self).enqueue(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
    end
    Sync.transaction do
      with_lock do
        candidates = if is_a?(ProviderConnection)
          self.syncs.incomplete.where(cancel_requested_at: nil).where("syncs.created_at > ?", Sync::STALE_AFTER.ago)
        else
          self.syncs.visible
        end
        if is_a?(ProviderConnection)
          # Queue order is defined by dependencies, including when timestamps
          # tie. An ancestor cannot receive a second concurrent successor.
          candidates = candidates.where.not(id: candidates.where.not(predecessor_id: nil).select(:predecessor_id))
        end
        sync = candidates.ordered.lock.first
        predecessor = nil
        if sync && sync.provider_window_frozen? && !sync.covers_window?(window_start_date, window_end_date)
          predecessor, sync = sync, nil
        end

        if sync
          Rails.logger.info("There is an existing recent sync, expanding window if needed (#{sync.id})")
          sync.expand_window_if_needed(window_start_date, window_end_date)

          # Update parent relationship if one is provided and sync doesn't already have a parent
          if parent_sync && !sync.parent_id
            sync.update!(parent: parent_sync)
          end
          # A lost delayed job can be recovered by a new explicit/scheduled sync
          # request while retaining its original identity and captured evidence.
          if is_a?(ProviderConnection) && sync.pending? && (!sync.resume_at || sync.resume_at <= Time.current) &&
              (!sync.predecessor || sync.predecessor.terminal?)
            SyncJob.perform_later(sync)
          end
        else
          sync = self.syncs.create!(
            parent: parent_sync,
            predecessor: predecessor,
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
    if Provider::AccountData::LegacyWriterFence.legacy_item?(self)
      Provider::AccountData::LegacyWriterFence.with_item(self, operation: :sync) do |current|
        current.send(:syncer).perform_sync(sync)
      end
    else
      syncer.perform_sync(sync)
    end
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
