class Rule::ConditionFilter::TransactionDetails < Rule::ConditionFilter
  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    # Search within the transaction's extra JSONB field
    # This allows matching on provider-specific details like SimpleFin payee, description, memo
    case operator
    when "like"
      # Case-insensitive search across all text values in the extra JSONB field
      sanitized_value = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      scope.where("transactions.extra::text ILIKE ?", sanitized_value)
    when "="
      # Exact match search across all text values in the extra JSONB field
      sanitized_value = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      scope.where("transactions.extra::text LIKE ?", sanitized_value)
    when "is_null"
      # Check if extra field is empty or null
      scope.where("transactions.extra IS NULL OR transactions.extra = '{}'::jsonb")
    else
      raise UnsupportedOperatorError, "Unsupported operator: #{operator} for transaction_details"
    end
  end
end
