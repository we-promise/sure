class Rule::ConditionFilter::TransactionAccount < Rule::ConditionFilter
  def type
    "select"
  end

  def options
    family.accounts.alphabetically.pluck(:name, :id)
  end

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    expression = build_sanitized_where_condition("accounts.id", operator, value)
    scope.where(expression)
  end
end
