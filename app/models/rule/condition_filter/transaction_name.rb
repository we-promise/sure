class Rule::ConditionFilter::TransactionName < Rule::ConditionFilter
  # Plaid joins the merchant name to the bank's own description, so "Target"
  # became "Target - TARGET 00023 SAN MATEO CA" (PlaidEntry::Processor#name).
  # That widened the text `=` and `!=` compare against, and those are the only
  # two operators here with no substring tolerance: an existing `= "Target"`
  # rule would quietly stop firing, and `!= "Target"` would quietly start,
  # matching the transactions it was written to exclude.
  #
  # For those two operators a Plaid row therefore also matches on the merchant
  # half alone — the text up to the separator. Every other operator is untouched,
  # and so is every row from any other source: `=` stays case-sensitive (LIKE,
  # never ILIKE) and a manually entered "Rent insurance" still does not satisfy
  # `name = "Rent"`.
  #
  # Scoped to Plaid deliberately. SimplefinEntry::Processor#name has always
  # emitted the same combined form, so SimpleFIN rules were written against
  # combined names from the start; widening them now would change a meaning the
  # user already chose, which is the thing this guard exists to prevent.
  PROVENANCE_AWARE_OPERATORS = %w[= !=].freeze

  def prepare(scope)
    scope.with_entry
  end

  def apply(scope, operator, value)
    unless PROVENANCE_AWARE_OPERATORS.include?(operator)
      return scope.where(build_sanitized_where_condition("entries.name", operator, value))
    end

    matches = plaid_aware_name_match(value)

    scope.where(operator == "=" ? matches : "NOT (#{matches})")
  end

  private
    # Returns SQL that is true when the name equals the value outright, or when a
    # Plaid row's name is that value followed by the separator and the bank's
    # description.
    #
    # entries.source is nullable, so the Plaid arm evaluates to NULL for manual
    # rows; `NOT (FALSE OR NULL)` is NULL, which would drop every manual row out
    # of a `!=` rule. COALESCE settles the whole predicate to a real boolean
    # before the negation sees it — the same hazard the `!=` operator handles
    # with IS DISTINCT FROM in Rule::ConditionFilter#sanitize_operator.
    #
    # @param value [String] the value the user wrote in the rule
    # @return [String] a sanitized SQL boolean expression
    def plaid_aware_name_match(value)
      normalized_value = normalize_value(value)
      normalized_field = normalize_field("entries.name")

      exact = ActiveRecord::Base.sanitize_sql_for_conditions([
        "#{normalized_field} = ?", normalized_value
      ])

      # LIKE, not ILIKE: `=` is case-sensitive today and this must not loosen it.
      combined = ActiveRecord::Base.sanitize_sql_for_conditions([
        "entries.source = ? AND #{normalized_field} LIKE ?",
        PlaidEntry::Processor::SOURCE,
        "#{ActiveRecord::Base.sanitize_sql_like(normalized_value)}#{PlaidEntry::Processor::NAME_SEPARATOR}%"
      ])

      "COALESCE(#{exact} OR (#{combined}), FALSE)"
    end
end
