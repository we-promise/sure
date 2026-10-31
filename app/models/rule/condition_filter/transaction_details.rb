class Rule::ConditionFilter::TransactionDetails < Rule::ConditionFilter
  def type
    "text"
  end

  # JSONB search only supports contains/equals/empty semantics, so we keep the
  # original operator set rather than inheriting the extended text operators.
  def operators
    [
      [ I18n.t("rules.condition_filters.operators.contains"), "like" ],
      [ I18n.t("rules.condition_filters.operators.equal_to"), "=" ],
      [ I18n.t("rules.condition_filters.operators.is_empty"), "is_null" ]
    ]
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
      #
      # Only the string and number values are searched, at any depth. Casting the
      # whole document to text also searched its keys and its true/false/null
      # literals, so a rule for "payment" or "description" matched every row whose
      # provider stored a key with that word in it, whatever the values said. Plaid
      # rows already carried pending and pending_transaction_id, which made
      # "pending", "transaction" and "id" match every one of them.
      sanitized_value = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      sql_operator = operator == "like" ? "ILIKE" : "LIKE"

      scope.where(<<~SQL.squish, sanitized_value)
        EXISTS (
          SELECT 1 FROM jsonb_path_query(transactions.extra, 'strict $.**') AS node
          WHERE jsonb_typeof(node) IN ('string', 'number')
            AND node #>> '{}' #{sql_operator} ?
        )
      SQL
    end
  end
end
