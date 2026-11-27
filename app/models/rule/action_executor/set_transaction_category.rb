class Rule::ActionExecutor::SetTransactionCategory < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    Category::Group.select_options(family.categories, indent: false)
  end

  def claimed_attributes
    [ :category_id ]
  end

  def actionable?(value)
    family.categories.exists?(id: value)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil, modified_transaction_ids: nil, already_modified_count: 0)
    category = family.categories.find_by_id(value)
    return 0 unless category

    scope = transaction_scope

    unless ignore_attribute_locks
      scope = scope.enrichable(:category_id)
    end

    count_modified_resources(scope, modified_transaction_ids: modified_transaction_ids) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :category_id,
        category.id,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end
end
