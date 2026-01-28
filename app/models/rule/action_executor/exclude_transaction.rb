class Rule::ActionExecutor::ExcludeTransaction < Rule::ActionExecutor
  def label
    "Exclude from budgeting and reports"
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    scope = transaction_scope.with_entry

    unless ignore_attribute_locks
      # Filter by entry's locked_attributes, not transaction's
      # Since excluded is on Entry, not Transaction, we need to check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'excluded'")
      )
    end

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the entry was actually modified, false otherwise
      txn.entry.enrich_attribute(
        :excluded,
        true,
        source: "rule"
      )
    end
  end
end
