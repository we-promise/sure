class Rule::ActionExecutor::SetTransactionTags < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    tag = family.tags.find_by_id(value)

    scope = transaction_scope

    unless ignore_attribute_locks
      scope = scope.enrichable(:tag_ids)
    end

    count_modified_resources(scope) do |txn|
      txn.enrich_attribute(
        :tag_ids,
        [ tag.id ],
        source: "rule"
      )
    end
  end
end
