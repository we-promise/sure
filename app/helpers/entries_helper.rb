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

  def entries_by_date(entries, totals: false)
    deduped_entries = dedupe_transfer_entries(entries)

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
end
