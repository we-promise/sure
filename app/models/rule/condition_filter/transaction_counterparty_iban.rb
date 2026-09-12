class Rule::ConditionFilter::TransactionCounterpartyIban < Rule::ConditionFilter
  def type
    "text"
  end

  # Overridden so the acronym reads correctly -- the base class's
  # key.humanize fallback would otherwise render this as "Transaction
  # counterparty iban" (lowercase "iban").
  def label
    I18n.t("rules.condition_filters.keys.transaction_counterparty_iban")
  end

  # An IBAN is an exact identifier, not free text -- "contains" would invite
  # false positives from unrelated digit sequences elsewhere in a
  # provider-formatted string. Restricting to equality/emptiness keeps this
  # filter precise, the same reasoning TransactionDetails uses for its own
  # narrowed operator set.
  def operators
    [
      [ I18n.t("rules.condition_filters.operators.equal_to"), "=" ],
      [ I18n.t("rules.condition_filters.operators.not_equal_to"), "!=" ],
      [ I18n.t("rules.condition_filters.operators.is_empty"), "is_null" ],
      [ I18n.t("rules.condition_filters.operators.is_not_empty"), "is_not_null" ]
    ]
  end

  def prepare(scope)
    scope
  end

  def apply(scope, operator, value)
    sanitize_operator(operator)

    # Monobank stores its counterparty IBAN nested under its own provider key
    # instead of the shared top-level counterparty_iban field (it predates
    # that convention and hasn't been migrated onto it), so this filter falls
    # back to it -- otherwise a Monobank user could never match this
    # condition even though the data exists on their transactions.
    #
    # The Monobank side is wrapped in the same normalization applied to
    # `normalized_value` below (strip whitespace, upcase): unlike
    # EnableBankingEntry::Processor, MonobankEntry::Processor stores
    # counter_iban as-is from the provider payload with no normalization
    # step, so comparing it unnormalized against a normalized user-entered
    # value would silently stop matching the moment Monobank's API ever
    # returns a differently-cased or spaced IBAN.
    field = "COALESCE(transactions.extra ->> 'counterparty_iban', " \
            "UPPER(REGEXP_REPLACE(transactions.extra -> 'monobank' ->> 'counter_iban', '\\s+', '', 'g')))"

    if operator == "is_null"
      scope.where("#{field} IS NULL")
    elsif operator == "is_not_null"
      scope.where("#{field} IS NOT NULL")
    else
      # Normalized the same way accounts.iban/merchants.iban and the stored
      # extra value are: a user pasting an IBAN with a tab, newline, or NBSP
      # (common when copying from a formatted PDF) must still match the
      # compact value Enable Banking stores.
      normalized_value = value.to_s.gsub(/[[:space:]]+/, "").upcase
      sql_operator = operator == "!=" ? "IS DISTINCT FROM" : "="

      scope.where(
        ActiveRecord::Base.sanitize_sql_for_conditions([ "#{field} #{sql_operator} ?", normalized_value ])
      )
    end
  end
end
