class Rule::ActionExecutor::SetTransactionNotes < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.set_transaction_notes")
  end

  def type
    "text"
  end

  def options
    nil
  end

  def claimed_attributes
    [ :notes ]
  end

  # A line appended by a rule above must not be overwritten.
  def blocking_attributes
    [ :notes, :appended_notes ]
  end

  # A blank value changes nothing, so it must not keep note rules below away.
  def actionable?(value)
    value.to_s.strip.present?
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    text = value.to_s.strip
    return 0 if text.blank?

    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      # Notes live on Entry, so check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'notes'")
      )
    end

    count_modified_resources(scope) do |txn|
      txn.entry.enrich_attribute(
        :notes,
        text,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end
end
