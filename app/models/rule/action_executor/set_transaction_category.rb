class Rule::ActionExecutor::SetTransactionCategory < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.categories_with_hierarchy.map { |c| [ c.name_with_indent, c.id ] }
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    category = family.categories.find_by_id(value)
    return 0 unless category

    scope = transaction_scope

    unless ignore_attribute_locks
      scope = scope.enrichable(:category_id)
    end

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :category_id,
        category.id,
        source: "rule"
      )
    end
  end
end
