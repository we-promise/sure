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

    # For a more intuitive UX, we do not want to show the same transfer twice
    # in the list. Show the leg that holds its category
    # (Transfer#category_transaction), so the category picker stays in the
    # list: the outflow, or the cash inflow of an investment withdrawal. The
    # inflow only replaces the outflow while both legs carry a transfer kind,
    # so day totals, which leave transfer kinds out, are unchanged.
    deduped_entries = transfer_groups.flat_map do |transfer_id, grouped_entries|
      if transfer_id.nil? || grouped_entries.size == 1
        grouped_entries
      else
        transfer = grouped_entries.first.entryable.transfer
        kept_inflow = transfer.categorizable? &&
          transfer.category_transaction.id == transfer.inflow_transaction_id &&
          transfer.inflow_transaction.transfer? && transfer.outflow_transaction.transfer?

        grouped_entries.reject do |e|
          e.entryable_type == "Transaction" &&
          (kept_inflow ? e.entryable.transfer_as_outflow.present? : e.entryable.transfer_as_inflow.present?)
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

  def entry_name_detailed(entry)
    [
      entry.date,
      format_money(entry.amount_money),
      entry.account.name,
      entry.name
    ].join(" • ")
  end
end
