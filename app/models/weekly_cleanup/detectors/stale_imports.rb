# Issue #3441 first-pass scope item 2: stale imports. Imports that failed
# recently or that are stuck in a processing state past Import::STUCK_AFTER
# (the same threshold SyncCleanerJob uses to reap them).
class WeeklyCleanup::Detectors::StaleImports < WeeklyCleanup::Detector
  def generate
    imports = family.imports.where(account_id: [ nil, *accounts.select(:id) ])
    failed = imports.where(status: "failed").where("imports.updated_at >= ?", window_start)
    stuck = imports.where(status: %w[importing reverting]).where("imports.updated_at < ?", Import::STUCK_AFTER.ago)
    scope = failed.or(stuck)

    samples = scope.order(updated_at: :desc).limit(MAX_SAMPLES).map do |import|
      "#{import.type.demodulize.underscore.humanize} — #{import.status} (#{import.updated_at.to_date})"
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.stale_imports.heading"),
      count: scope.count,
      samples: samples
    )
  end
end
