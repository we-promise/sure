class Rule::ActionExecutor::SetTransactionTags < Rule::ActionExecutor
  def type
    "multi_select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    tag_ids = Array(value).compact_blank
    selected_tag_ids = family.tags.where(id: tag_ids).pluck(:id)
    return 0 if selected_tag_ids.empty?

    scope = transaction_scope

    unless ignore_attribute_locks
      scope = scope.enrichable(:tag_ids)
    end

    count_modified_resources(scope) do |txn|
      # `with_lock` closes the read-modify-write race window: without it, two
      # concurrent rule applications on the same transaction could each read
      # the same "before" tag_ids and one write could clobber the other.
      txn.with_lock do
        # Merge the selected tags with existing tags instead of replacing them
        # This preserves tags set by users or other rules
        existing_tag_ids = txn.tag_ids || []
        merged_tag_ids = (existing_tag_ids + selected_tag_ids).uniq

        txn.enrich_attribute(
          :tag_ids,
          merged_tag_ids,
          source: "rule",
          ignore_locks: ignore_attribute_locks
        )
      end
    end
  end
end
