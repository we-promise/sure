# Issue #3441 first-pass scope item 1: uncategorized or hard-to-categorize
# transactions. Surfaces recent standard transactions that landed without a
# category so an admin can triage them.
class WeeklyCleanup::Detectors::UncategorizedTransactions < WeeklyCleanup::Detector
  def generate
    scope = recent_standard_entries.where(transactions: { category_id: nil })
    samples = scope.includes(:entryable).order(date: :desc).limit(MAX_SAMPLES).map do |entry|
      "#{entry.date} — #{entry.name} (#{entry.amount_money.format})"
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.uncategorized_transactions.heading"),
      count: scope.count,
      samples: samples
    )
  end
end
