class FamilyExport < ApplicationRecord
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

  def filename
    "sure_export_#{created_at.strftime('%Y%m%d_%H%M%S')}.zip"
  end

  def downloadable?
    completed? && export_file.attached?
  end
end
