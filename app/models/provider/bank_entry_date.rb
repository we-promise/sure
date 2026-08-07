# frozen_string_literal: true

# Selects the user-facing `entries.date` for bank/provider transaction imports.
#
# Provider booking/posting/settlement fields are provenance — they should live
# in `transaction.extra[source]` — and must not always become the Sure entry date
# when they fall in the future (see #2907).
#
# Preference order is caller-defined. Among present Date values, the first that
# is on or before `as_of` wins. If every candidate is in the future, clamp to
# `as_of` on first import so activity/budgets/transfer matching stay current.
# On resync, pass `existing_date:` so a still-all-future payload does not advance
# the clamped date day-by-day; once a real ≤-as_of candidate appears, it wins.
# Pass `as_of: family_today(family)` so "future" is judged in the family's
# timezone, not the server/UTC calendar date. Investment processors should not
# use this helper blindly (future settlement can be valid).
class Provider::BankEntryDate
  def self.family_today(family = nil)
    Time.current.in_time_zone(family&.timezone).to_date
  end

  def self.existing_entry_date(account:, external_id:, source:)
    return nil if account.nil? || external_id.blank? || source.blank?

    account.entries.where(external_id: external_id, source: source).pick(:date)
  end

  def self.select(candidates, as_of: Date.current, existing_date: nil)
    dates = Array(candidates).filter_map do |candidate|
      date = candidate.is_a?(Array) ? candidate.last : candidate
      date if date.is_a?(Date)
    end

    return nil if dates.empty?

    dates.find { |date| date <= as_of } ||
      (existing_date.is_a?(Date) && existing_date <= as_of ? existing_date : as_of)
  end

  # Compact string provenance for nesting under transaction.extra[source].
  # Accepts [[key, raw_or_date], ...] and skips blanks.
  def self.provenance(fields)
    Array(fields).each_with_object({}) do |(key, value), hash|
      next if value.blank?

      hash[key.to_s] = value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
    end
  end
end
