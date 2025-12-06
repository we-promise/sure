class Rule::ActionExecutor::SetTransactionName < Rule::ActionExecutor
  def type
    "text"
  end

  def options
    nil
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    return 0 if value.blank?

    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      # Filter by entry's locked_attributes, not transaction's
      # Since name is on Entry, not Transaction, we need to check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'name'")
      )
    end

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the entry was actually modified, false otherwise
      txn.entry.enrich_attribute(
        :name,
        value,
        source: "rule"
      )
    end
  end
end
