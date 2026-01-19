class Rule::ActionExecutor::SetTransactionTags < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    tag = family.tags.find_by_id(value)
    return 0 unless tag

    scope = transaction_scope

    unless ignore_attribute_locks
      scope = scope.enrichable(:tag_ids)
    end

    count_modified_resources(scope) do |txn|
      # Merge the new tag with existing tags instead of replacing them
      # This preserves tags set by users or other rules
      existing_tag_ids = txn.tag_ids || []
      merged_tag_ids = (existing_tag_ids + [ tag.id ]).uniq

      txn.enrich_attribute(
        :tag_ids,
        merged_tag_ids,
        source: "rule"
      )
    end
  end
end
