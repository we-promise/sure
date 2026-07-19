class FamilyExport < ApplicationRecord
  # See Import::STUCK_AFTER — same dead-worker failure mode. Exports build in
  # minutes, so a shorter window; a wedged pending/processing export otherwise
  # spins in the UI forever (the exports index polls while any is in flight).
  STUCK_AFTER = 2.hours

  belongs_to :family

  has_one_attached :export_file, dependent: :purge_later

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    failed: "failed"
  }, default: :pending, validate: true

  scope :ordered, -> { order(created_at: :desc) }

  # See Import::PRESUMED_LOST_AFTER — same dead-worker failure mode. Exports
  # build in minutes; a pending/processing export idle for an hour is lost.
  PRESUMED_LOST_AFTER = 1.hour

  def presumed_lost?
    (pending? || processing?) && updated_at < PRESUMED_LOST_AFTER.ago
  end

  # Escape hatch for exports whose background job died mid-flight; the
  # with_lock re-check means a job finishing between render and click wins.
  # Export generation is in-memory, so nothing is left behind — the user
  # simply creates a new export.
  def force_fail!
    with_lock do
      return false unless presumed_lost?

      update!(status: :failed)
    end

    true
  end

  def self.clean
    where(status: [ :pending, :processing ])
      .where("updated_at < ?", STUCK_AFTER.ago)
      .includes(:family)
      .find_each do |export|
        # Read before the lock — see Import.reap_stuck!.
        family = export.family

        # Row-lock + staleness re-check before mutating, as Sync#perform
        # does since #2680 — the export job may have finished in between.
        export.with_lock do
          next unless %w[pending processing].include?(export.status) && export.updated_at < STUCK_AFTER.ago

          previous_status = export.status
          export.update!(status: :failed)

          DebugLogEntry.capture(
            category: "background_jobs",
            level: "warn",
            message: "Reaped FamilyExport stuck in #{previous_status} for over #{STUCK_AFTER.inspect}",
            source: name,
            family: family,
            metadata: { record_type: name, record_id: export.id, previous_status: previous_status, new_status: "failed" }
          )
        end
      end
  end

  def filename
    "sure_export_#{created_at.strftime('%Y%m%d_%H%M%S')}.zip"
  end

  def downloadable?
    completed? && export_file.attached?
  end
end
