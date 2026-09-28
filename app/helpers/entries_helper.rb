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
    deduped_entries = entries_without_duplicate_transfers(entries)

    deduped_entries.group_by(&:date).sort.reverse_each.map do |date, grouped_entries|
      content = capture do
        yield grouped_entries
      end

      next if content.blank?

      render partial: "entries/entry_group", locals: { date:, entries: grouped_entries, content:, totals: }
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

  # Hide the inflow only when both transfer legs are on this page. Rejecting
  # in place preserves the query order, including amount sorting across dates.
  def entries_without_duplicate_transfers(entries)
    outflow_transfer_ids = entries.filter_map do |entry|
      entry.entryable.transfer_as_outflow&.id if entry.entryable_type == "Transaction"
    end.to_set

    entries.reject do |entry|
      entry.entryable_type == "Transaction" &&
        entry.entryable.transfer_as_inflow&.id.in?(outflow_transfer_ids)
    end
  end
end
