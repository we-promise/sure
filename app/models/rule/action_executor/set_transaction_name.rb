class Rule::ActionExecutor::SetTransactionName < Rule::ActionExecutor
  def type
    "text"
  end

  def options
    nil
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false)
    return 0 if value.blank?

    scope = transaction_scope
    unless ignore_attribute_locks
      scope = scope.enrichable(:name)
    end

    count_modified_resources(scope) do |txn|
      txn.entry.enrich_attribute(
        :name,
        value,
        source: "rule"
      )
    end
  end
end
