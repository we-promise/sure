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

  def self.clean
    where(status: [ :pending, :processing ])
      .where("updated_at < ?", STUCK_AFTER.ago)
      .find_each do |export|
        previous_status = export.status
        export.update!(status: :failed)

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Reaped FamilyExport stuck in #{previous_status} for over #{STUCK_AFTER.inspect}",
          source: name,
          family: export.family,
          metadata: { record_type: name, record_id: export.id, previous_status: previous_status, new_status: "failed" }
        )
      end
  end

  def filename
    "sure_export_#{created_at.strftime('%Y%m%d_%H%M%S')}.zip"
  end

  def downloadable?
    completed? && export_file.attached?
  end
end
