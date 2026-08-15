class ClearAiCacheJob < ApplicationJob
  queue_as :low_priority

  # The reset runs in the background with no UI of its own, so /settings/debug is
  # the only place an operator can see whether it ran. Its own category keeps a
  # single run filterable there.
  DEBUG_CATEGORY = "ai_cache_reset"

  # Both models carry AI-sourced enrichments: categories and merchants land on
  # Transaction, entry-level attributes on Entry. Keyed by the label used in the
  # debug log so the entries read the way an operator thinks about them.
  CLEARABLE_MODELS = { "transactions" => "Transaction", "entries" => "Entry" }.freeze

  # A family-wide problem would otherwise write one debug entry per record. The
  # full tally still lands in the completion entry's metadata.
  MAX_LOGGED_RECORD_ERRORS = 5

  def perform(family)
    if family.nil?
      capture("warn", "AI cache reset skipped: job received no family")
      return
    end

    capture("info", "AI cache reset started", family: family)

    removed = {}
    failures = {}
    skipped = {}

    CLEARABLE_MODELS.each do |label, model_name|
      removed[label], scope_skipped = clear_scope(family, label, model_name.constantize)
      skipped[label] = scope_skipped if scope_skipped.positive?
    rescue => e
      removed[label] = 0
      failures[label] = "#{e.class}: #{e.message}"
      capture(
        "error",
        "AI cache reset failed while clearing #{label}: #{e.class}: #{e.message}",
        family: family,
        metadata: { scope: label, error_class: e.class.name, error_message: e.message }
      )
    end

    capture(
      "info",
      completion_message(removed, failures, skipped),
      family: family,
      metadata: {
        entries_removed: removed.values.sum,
        removed_by_scope: removed,
        failed_scopes: failures,
        skipped_records: skipped
      }
    )
  end

  private
    # Per-record failures are warned about (up to a cap) and counted rather than
    # raised, so one unclearable transaction can't wipe out the whole family's
    # reset — or the count of what it did clear. Returns [removed, skipped].
    def clear_scope(family, label, model)
      logged_errors = 0
      skipped = 0

      removed = model.clear_ai_cache(family) do |record, error|
        skipped += 1

        next if logged_errors >= MAX_LOGGED_RECORD_ERRORS

        logged_errors += 1
        capture(
          "warn",
          "AI cache reset could not clear #{label.singularize} #{record.id}: #{error.class}: #{error.message}",
          family: family,
          metadata: { scope: label, record_id: record.id, error_class: error.class.name, error_message: error.message }
        )
      end

      [ removed, skipped ]
    end

    def completion_message(removed, failures, skipped)
      total = removed.values.sum
      breakdown = removed.map { |label, count| "#{label}: #{count}" }.join(", ")

      message = failures.any? ? "AI cache reset completed with errors" : "AI cache reset completed"
      message += ": removed #{total} AI cache #{'entry'.pluralize(total)} (#{breakdown})"
      message += ". Failed to clear: #{failures.keys.join(', ')}" if failures.any?

      if skipped.any?
        skipped_total = skipped.values.sum
        message += ". Skipped #{skipped_total} #{'record'.pluralize(skipped_total)} that could not be cleared"
      end

      message
    end

    def capture(level, message, family: nil, metadata: {})
      DebugLogEntry.capture(
        category: DEBUG_CATEGORY,
        level: level,
        message: message,
        source: self.class.name,
        family: family,
        metadata: metadata
      )
    end
end
