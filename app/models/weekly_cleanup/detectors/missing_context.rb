# Issue #3441 first-pass scope item 6: missing receipts, notes, or transaction
# context. Flags recent larger expenses with neither a note nor an attachment —
# the transactions most likely to need "what was this?" context later.
class WeeklyCleanup::Detectors::MissingContext < WeeklyCleanup::Detector
  AMOUNT_THRESHOLD = 100

  def generate
    scope = recent_standard_entries
      .where("entries.amount >= ?", AMOUNT_THRESHOLD)
      .where("entries.notes IS NULL OR entries.notes = ''")
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM active_storage_attachments asa
          WHERE asa.record_type = 'Transaction' AND asa.record_id = transactions.id AND asa.name = 'attachments'
        )
      SQL

    samples = scope.includes(:entryable).order(amount: :desc).limit(MAX_SAMPLES).map do |entry|
      "#{entry.date} — #{entry.name} (#{entry.amount_money.format})"
    end

    finding(
      heading: I18n.t("weekly_cleanup.detectors.missing_context.heading"),
      count: scope.count,
      samples: samples
    )
  end
end
