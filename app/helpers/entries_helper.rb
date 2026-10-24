module EntriesHelper
  SplitGroup = Data.define(:parent, :children)

  # True for rows the current list render flagged as unread (see
  # UnreadEntriesTrackable). Renders outside those lists (turbo stream
  # replacements, broadcasts) have no set and show no dot.
  def unread_entry?(entry)
    @unread_entry_ids&.include?(entry.id) || false
  end

  # When the list on this page was loaded, for the "mark all as read" button
  # (see UnreadEntriesTrackable#note_unread_as_of).
  def unread_as_of_param
    @unread_as_of&.iso8601(6)
  end

  # Only present on responses to Turbo hover-prefetches: marks the rows read
  # from the browser when the page is actually shown.
  def unread_marker_tag
    return if @unread_entry_ids_to_mark_on_display.blank?

    tag.div hidden: true, data: {
      controller: "unread-marker",
      unread_marker_url_value: transactions_read_path,
      unread_marker_entry_ids_value: @unread_entry_ids_to_mark_on_display.to_a
    }
  end

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

  def entry_name_detailed(entry)
    [
      entry.date,
      format_money(entry.amount_money),
      entry.account.name,
      entry.name
    ].join(" • ")
  end
end
