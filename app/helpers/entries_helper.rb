module EntriesHelper
  SplitGroup = Data.define(:parent, :children)

  def group_split_entries(entries, split_parents)
    return entries if split_parents.blank?

    result = []
    seen_parent_ids = Set.new

    entries.each do |entry|
      if entry.split_child? && split_parents[entry.parent_entry_id]
        parent_id = entry.parent_entry_id
        next if seen_parent_ids.include?(parent_id)

        seen_parent_ids.add(parent_id)
        children = entries.select { |e| e.parent_entry_id == parent_id }
        result << SplitGroup.new(parent: split_parents[parent_id], children: children)
      else
        result << entry
      end
    end

    result
  end

  def entries_by_date(entries, totals: false)
    transfer_groups = entries.group_by do |entry|
      # Only check for transfer if it's a transaction
      next nil unless entry.entryable_type == "Transaction"
      entry.entryable.transfer&.id
    end

    # For a more intuitive UX, we do not want to show the same transfer twice in the list
    deduped_entries = transfer_groups.flat_map do |transfer_id, grouped_entries|
      if transfer_id.nil? || grouped_entries.size == 1
        grouped_entries
      else
        grouped_entries.reject do |e|
          e.entryable_type == "Transaction" &&
          e.entryable.transfer_as_inflow.present?
        end
      end
    end

    deduped_entries.group_by(&:date).sort.reverse_each.map do |date, grouped_entries|
      content = capture do
        yield grouped_entries
      end

      next if content.blank?

      render partial: "entries/entry_group", locals: { date:, entries: grouped_entries, content:, totals: }
    end.compact.join.html_safe
  end

  # Day-group total converted to the family's base currency (issue #2622).
  #
  # Returns nil when there is nothing to convert (all entries are already in
  # the base currency) or when a needed exchange rate is not cached locally —
  # callers should fall back to the per-currency breakdown.
  def entry_group_base_currency_total(entries, date)
    family = Current.family
    return nil unless family

    items = entries.reject do |entry|
      entry.entryable_type == "Transaction" && entry.entryable.transfer?
    end

    currencies = items.map(&:currency).uniq
    return nil if currencies.empty? || currencies == [ family.currency ]

    market_rates = {}

    total = items.sum(Money.new(0, family.currency)) do |entry|
      next entry.amount_money if entry.currency == family.currency

      # A transaction can carry its own rate (entry currency -> account
      # currency), which is what balance syncing uses to value the entry —
      # honor it so the day total agrees with the account's converted amounts.
      custom_rate = entry.entryable.exchange_rate if entry.entryable.respond_to?(:exchange_rate)

      if custom_rate.present?
        in_account_currency = Money.new(entry.amount * custom_rate, entry.account.currency)
        next in_account_currency if entry.account.currency == family.currency

        rate = market_rates[entry.account.currency] ||= ExchangeRate.find_cached_rate(from: entry.account.currency, to: family.currency, date: date)
        return nil if rate.nil?

        in_account_currency.exchange_to(family.currency, custom_rate: rate.rate)
      else
        rate = market_rates[entry.currency] ||= ExchangeRate.find_cached_rate(from: entry.currency, to: family.currency, date: date)
        return nil if rate.nil?

        entry.amount_money.exchange_to(family.currency, custom_rate: rate.rate)
      end
    end

    -total
  end

  def entry_name_detailed(entry)
    [
      entry.date,
      format_money(entry.amount_money),
      entry.account.name,
      entry.name
    ].join(" • ")
  end
end
