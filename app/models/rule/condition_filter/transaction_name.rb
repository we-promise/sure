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

  # The name lives on entries, so the join has to exist before apply runs.
  #
  # @param scope [ActiveRecord::Relation] transactions the rule runs against
  # @return [ActiveRecord::Relation] the scope joined to entries
  def prepare(scope)
    scope.with_entry
  end

  # @param scope [ActiveRecord::Relation] the prepared scope
  # @param operator [String] one of the text operators this filter offers
  # @param value [String] the value the user wrote in the rule
  # @return [ActiveRecord::Relation] the scope narrowed to matching rows
  def apply(scope, operator, value)
    unless PROVENANCE_AWARE_OPERATORS.include?(operator)
      return scope.where(build_sanitized_where_condition("entries.name", operator, value))
    end

    scope.where(plaid_aware_name_condition(operator, value))
  end

  private
    # True when the name equals the value outright, or when a Plaid row's name is
    # that value followed by the separator and the bank's description.
    #
    # entries.source is nullable, so the Plaid arm evaluates to NULL for manual
    # rows; `NOT (FALSE OR NULL)` is NULL, which would drop every manual row out
    # of a `!=` rule. COALESCE settles the predicate to a real boolean before the
    # negation sees it — the same hazard `!=` handles with IS DISTINCT FROM in
    # Rule::ConditionFilter#sanitize_operator.
    #
    # Every user-supplied value is bound, and the only interpolations are the
    # field expression built from the "entries.name" literal by normalize_field
    # and the two frozen constants, so the whole condition leaves here as one
    # sanitized string.
    #
    # @param operator [String] "=" or "!="
    # @param value [String] the value the user wrote in the rule
    # @return [String] a sanitized SQL boolean expression
    def plaid_aware_name_condition(operator, value)
      normalized_value = normalize_value(value)
      field = normalize_field("entries.name")

      # LIKE, not ILIKE: `=` is case-sensitive today and this must not loosen it.
      match = "COALESCE(#{field} = ? OR (entries.source = ? AND #{field} LIKE ?), FALSE)"

      ActiveRecord::Base.sanitize_sql_for_conditions([
        operator == "=" ? match : "NOT (#{match})",
        normalized_value,
        PlaidEntry::Processor::SOURCE,
        "#{ActiveRecord::Base.sanitize_sql_like(normalized_value)}#{PlaidEntry::Processor::NAME_SEPARATOR}%"
      ])
    end
end
