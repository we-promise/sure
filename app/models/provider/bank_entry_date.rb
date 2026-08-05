# frozen_string_literal: true

# Selects the user-facing `entries.date` for bank/provider transaction imports.
#
# Provider booking/posting/settlement fields are provenance — they should live
# in `transaction.extra[source]` — and must not always become the Sure entry date
# when they fall in the future (see #2907).
#
# Preference order is caller-defined. Among present Date values, the first that
# is on or before `as_of` wins. If every candidate is in the future, clamp to
# `as_of` so activity/budgets/transfer matching stay current. Investment
# processors should not use this helper blindly (future settlement can be valid).
class Provider::BankEntryDate
  def self.select(candidates, as_of: Date.current)
    dates = Array(candidates).filter_map do |candidate|
      date = candidate.is_a?(Array) ? candidate.last : candidate
      date if date.is_a?(Date)
    end

    return nil if dates.empty?

    dates.find { |date| date <= as_of } || as_of
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
