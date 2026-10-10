# Issue #3441 first-pass scope item 5: duplicate or overlapping imported data.
# Flags import-created entries that look duplicated: same account, date,
# amount, and normalized name appearing more than once in the window.
class WeeklyCleanup::Detectors::DuplicateImportedEntries < WeeklyCleanup::Detector
  DUPLICATE_WINDOW = 30.days

  def generate
    groups = family.entries
      .where.not(import_id: nil)
      .where("entries.date >= ?", DUPLICATE_WINDOW.ago.to_date)
      .group(:account_id, :date, :amount, Arel.sql("lower(entries.name)"))
      .having("COUNT(*) > 1")
      .pluck(:account_id, :date, :amount, Arel.sql("lower(entries.name)"), Arel.sql("COUNT(*)"))

    samples = groups.first(MAX_SAMPLES).map do |account_id, date, amount, name, n|
      account_name = family.accounts.detect { |a| a.id == account_id }&.name || "?"
      "#{date} — #{name} (#{n}x, #{account_name})"
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.duplicate_imported_entries.heading"),
      count: groups.size,
      samples: samples
    )
  end
end
