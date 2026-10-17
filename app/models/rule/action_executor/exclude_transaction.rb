class Rule::ActionExecutor::ExcludeTransaction < Rule::ActionExecutor
  def label
    "Exclude from budgeting and reports"
  end

  def claimed_attributes
    [ :excluded ]
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
      # Excluding an EMI-linked entry silently breaks the plan's arithmetic.
      # Budget analytics filter on entries.excluded, so excluding an
      # installment drops real money movement out of income statement and
      # budget totals while the balance (computed from every non-pending
      # entry, see Balance::SyncCache#converted_entries) keeps counting it --
      # the spend would exist in one report and not the other, with no
      # schedule left to explain the gap. Skipped silently, same as the
      # transfer conversion in SetAsTransferOrPayment, rather than raising
      # part-way through the batch and halting every other transaction in the
      # rule run.
      next false if txn.entry.emi_linked?

      # enrich_attribute returns true if the entry was actually modified, false otherwise
      txn.entry.enrich_attribute(
        :excluded,
        true,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end
end
