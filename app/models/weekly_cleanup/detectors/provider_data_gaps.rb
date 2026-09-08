# Issue #3441 first-pass scope item 3: missing data from connected providers.
# Flags recent failed or stale sync runs for syncables that belong to this
# family (provider items, the family umbrella sync, etc.) — a failed/stale
# sync means fresh provider data is not flowing.
class WeeklyCleanup::Detectors::ProviderDataGaps < WeeklyCleanup::Detector
  def generate
    recent = Sync.where(status: %w[failed stale]).where("syncs.created_at >= ?", window_start)
    count = 0
    samples = []

    recent.distinct.pluck(:syncable_type).each do |type|
      klass = type.safe_constantize
      next unless klass&.column_names&.include?("family_id")

      owned = recent.where(syncable_type: type, syncable_id: klass.where(family_id: family.id).select(:id))
      count += owned.count
      owned.order(created_at: :desc).limit(MAX_SAMPLES).each do |sync|
        samples << "#{type.underscore.humanize} — #{sync.status} (#{sync.created_at.to_date})"
      end
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.provider_data_gaps.heading"),
      count: count,
      samples: samples.first(MAX_SAMPLES)
    )
  end
end
