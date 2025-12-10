class Rule::ConditionFilter::TransactionDetails < Rule::ConditionFilter
  def type
    "text"
  end

  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    # Search within the transaction's extra JSONB field
    # This allows matching on provider-specific details like SimpleFin payee, description, memo

    # Validate operator using parent class method
    sanitize_operator(operator)

    if operator == "is_null"
      # Check if extra field is empty or null
      scope.where("transactions.extra IS NULL OR transactions.extra = '{}'::jsonb")
    else
      # For both "like" and "=" operators, perform contains search
      # "like" is case-insensitive (ILIKE), "=" is case-sensitive (LIKE)
      # Note: For JSONB fields, both operators use contains semantics rather than exact match
      # because searching within structured JSON data makes contains more useful than exact equality
      sanitized_value = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      sql_operator = operator == "like" ? "ILIKE" : "LIKE"

      scope.where("transactions.extra::text #{sql_operator} ?", sanitized_value)
    end
  end
end
