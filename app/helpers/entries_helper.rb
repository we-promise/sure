module EntriesHelper
  SplitGroup = Data.define(:parent, :children)

  # Groups split-child entries under their parent, preserving list order.
  # Children whose parent isn't loaded render as plain entries.
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

  # Picks the compact partial and locals for an account-activity entry based on
  # its entryable type. Unknown types fall back to rendering the entry itself.
  def compact_entry_render_options(entry, view_ctx: "account", is_filtered: false, in_split_group: false, running_balance: nil, hide_balance: false, flat: false)
    partial = {
      "Transaction" => "transactions/compact_transaction",
      "Trade" => "trades/compact_trade",
      "Valuation" => "valuations/compact_valuation"
    }[entry.entryable_type]
    return { partial: entry, locals: { view_ctx: view_ctx, is_filtered: is_filtered } } unless partial

    locals = { entry: entry, running_balance: running_balance, hide_balance: hide_balance, flat: flat }
    unless entry.entryable_type == "Valuation"
      locals.merge!(view_ctx: view_ctx, is_filtered: is_filtered, in_split_group: entry.entryable_type == "Transaction" && in_split_group)
    end
    { partial: partial, locals: locals }
  end

  # Drops the inflow leg of transfers whose both legs are listed, keeping the
  # original order so flat (ungrouped) lists stay chronological.
  def dedupe_transfer_entries(entries)
    # For a more intuitive UX, we do not want to show the same transfer twice
    # in the list. We count occurrences by transfer id first (without
    # reordering the entries) so we only need to decide, per entry, whether
    # it's the inflow side of a transfer that appears more than once.
    transfer_counts = entries.filter_map do |entry|
      entry.entryable.transfer&.id if entry.entryable_type == "Transaction"
    end.tally

    entries.reject do |entry|
      entry.entryable_type == "Transaction" &&
        transfer_counts[entry.entryable.transfer&.id].to_i > 1 &&
        entry.entryable.transfer_as_inflow.present?
    end
  end

  # Groups entries by date (newest first) after transfer dedup, yielding each
  # day's entries for rendering inside an entry-group section.
  def entries_by_date(entries, totals: false, compact: false)
    deduped_entries = dedupe_transfer_entries(entries)

    deduped_entries.group_by(&:date).sort.reverse_each.map do |date, grouped_entries|
      content = capture do
        yield grouped_entries
      end

      next if content.blank?

      render partial: "entries/entry_group", locals: { date:, entries: grouped_entries, content:, totals:, compact: }
    end.compact.join.html_safe
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
