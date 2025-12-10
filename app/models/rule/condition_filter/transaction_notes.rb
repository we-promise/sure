class Rule::ConditionFilter::TransactionNotes < Rule::ConditionFilter
  def type
    "text"
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    expression = build_sanitized_where_condition("entries.notes", operator, value)
    scope.where(expression)
  end
end
