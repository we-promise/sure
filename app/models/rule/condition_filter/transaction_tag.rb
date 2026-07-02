class Rule::ConditionFilter::TransactionTag < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def prepare(scope)
    scope.left_joins(:tags)
  end

  def apply(scope, operator, value)
    # Supported "select" operators are "=" (has this tag) and "is_null" (no tags).
    # Neither can match a transaction's tag join more than once, so no DISTINCT is
    # needed — and omitting it keeps the relation structurally compatible with the
    # other filters when combined in a compound OR condition.
    expression = build_sanitized_where_condition("tags.id", operator, value)
    scope.where(expression)
  end
end
