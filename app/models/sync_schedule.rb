# How often one provider connection syncs on its own. A connection without a
# schedule only takes part in the family sync (AutoSyncScheduler /
# SyncAllJob, the once-a-day sync on login, and "Sync all"). A schedule
# shorter than a day syncs it in between, on top of the family sync; a
# schedule of a day or longer replaces the family sync for that connection
# (see `without_own_daily_schedule`). SyncScheduledItemsJob ticks every TICK
# and syncs whatever has come due.
#
# Per connection rather than global because connections differ in what a
# sync costs: Plaid bills per transactions refresh and banks rate-limit,
# while an exchange API key is cheap to poll every few minutes.
class SyncSchedule < ApplicationRecord
  TICK = 15.minutes

  # Offered intervals, in minutes. Each either divides a day or is a whole
  # number of days, so with next_run_at aligned to multiples of the interval
  # a connection syncs at the same clock time instead of drifting.
  INTERVALS = [ 15, 30, 60, 120, 240, 360, 720, 1440, 4320, 10080, 20160 ].freeze

  # Schedules at least this long take their connection out of the family
  # sync, so a slow-changing connection is not synced (and, for Plaid, billed
  # a transactions refresh) every day regardless of its schedule.
  DAILY_MINUTES = 1440

  belongs_to :syncable, polymorphic: true

  validates :interval_minutes, inclusion: { in: INTERVALS }
  validates :syncable_type, inclusion: { in: ->(_schedule) { schedulable_associations.keys } }
  validates :syncable_id, uniqueness: { scope: :syncable_type }

  before_validation :align_next_run_at, if: -> { interval_minutes_changed? || next_run_at.blank? }

  scope :due, -> { where(next_run_at: ..Time.current) }
  scope :replacing_family_sync, -> { where(interval_minutes: DAILY_MINUTES..) }

  class << self
    # `items` (a relation of one provider's items) without the connections
    # whose own schedule of a day or longer replaces the family sync.
    def without_own_daily_schedule(items)
      items.where.not(
        id: replacing_family_sync.where(syncable_type: items.klass.polymorphic_name).select(:syncable_id)
      )
    end

    # The connections a schedule may point at, as { class name => Family
    # association }: every `*_items` association whose model is Syncable,
    # the same set the daily family sync fans out to.
    def schedulable_associations
      Family::Syncer.syncable_item_associations.to_h do |association|
        [ Family.reflect_on_association(association).klass.name, association ]
      end
    end

    # Sets `syncable`'s interval, creating its schedule on first use, and
    # returns the schedule (with errors if the interval is rejected). Two
    # requests creating the same connection's schedule at once both pass
    # the uniqueness validation; the one the unique index turns away applies
    # its interval to the row the other created.
    def assign(syncable, interval_minutes)
      schedule = syncable.sync_schedule || syncable.build_sync_schedule
      schedule.interval_minutes = interval_minutes
      schedule.save
      schedule
    rescue ActiveRecord::RecordNotUnique
      schedule = syncable.reload_sync_schedule
      schedule.interval_minutes = interval_minutes
      schedule.save
      schedule
    end

    # Whether `user` may change `syncable`'s schedule: admins manage every
    # connection, a member only one they own on a provider that allows it
    # (ProviderItemOwnable). A connection being deleted takes no schedule.
    def editable_by?(syncable, user)
      return false if user.nil? || syncable.try(:scheduled_for_deletion?)

      if syncable.respond_to?(:manageable_by?)
        syncable.manageable_by?(user)
      else
        user.admin?
      end
    end
  end

  def interval
    interval_minutes.minutes
  end

  def replaces_family_sync?
    interval_minutes.to_i >= DAILY_MINUTES
  end

  # Moves a due schedule to the first boundary after `from` and returns
  # whether it was due. Locked and reloaded first, so the interval saved
  # since this row was loaded is the one the next run is counted in, and a
  # schedule changed meanwhile (which realigns it to the future) or removed
  # is not run.
  def advance!(from: Time.current)
    with_lock do
      next false if next_run_at > from

      update!(next_run_at: next_boundary_after(from))
      true
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  private
    def align_next_run_at
      return unless INTERVALS.include?(interval_minutes)

      self.next_run_at = next_boundary_after(Time.current)
    end

    # Multiples of the interval counted from the Unix epoch, i.e. from
    # midnight UTC: "every 6 hours" runs at 00:00, 06:00, 12:00 and 18:00.
    def next_boundary_after(time)
      seconds = interval.to_i
      Time.zone.at((time.to_i / seconds + 1) * seconds)
    end
end
