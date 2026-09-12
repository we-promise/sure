# Issue #3441 first-pass scope item 4: missing or suspicious merchant/category
# information. Surfaces recent standard transactions with no merchant linked —
# these are the rows most likely to also be miscategorized.
class WeeklyCleanup::Detectors::MissingMerchantInfo < WeeklyCleanup::Detector
  def generate
    scope = recent_standard_entries.where(transactions: { merchant_id: nil })
    samples = scope.includes(:entryable).order(date: :desc).limit(MAX_SAMPLES).map do |entry|
      "#{entry.date} — #{entry.name} (#{entry.amount_money.format})"
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.missing_merchant_info.heading"),
      count: scope.count,
      samples: samples
    )
  end
end
