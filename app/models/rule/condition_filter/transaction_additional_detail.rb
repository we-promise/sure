# Matches a single named field inside a transaction's `extra` JSONB -- the data shown under
# "Additional details" on the transaction page.
#
# Rule::ConditionFilter::TransactionDetails searches every value in that document at any
# depth, so a rule for "5411" also fires on a provider id or payment reference that merely
# contains those digits. This filter is key-scoped instead: the transaction must carry the
# named field *and* its value must match, which is what makes it usable for things like a
# merchant category code.
#
# rule_conditions stores a single `value`, so the key and the comparison value share it,
# separated by the first "=":
#
#   merchant_category_code=5411   field exists and equals 5411
#   merchant_category_code        field exists, whatever its value -- including JSON null,
#                                 which is a field the provider sent as empty, not an
#                                 absent one
#
# The field is looked up at any depth, so the caller does not need to know the provider
# namespace it sits under ("redbark", "plaid", ...).
class Rule::ConditionFilter::TransactionAdditionalDetail < Rule::ConditionFilter
  KEY_VALUE_SEPARATOR = "="

  def type
    "text"
  end

  def label
    I18n.t("rules.condition_filters.transaction_additional_detail.label")
  end

  # JSONB lookup supports equality and contains semantics only; the inherited text
  # operators (regex, starts_with, ...) would need a different query shape.
  def operators
    [
      [ I18n.t("rules.condition_filters.operators.equal_to"), "=" ],
      [ I18n.t("rules.condition_filters.operators.contains"), "like" ]
    ]
  end

  def apply(scope, operator, value)
    # Validate the operator against the set above before it reaches any SQL.
    sanitize_operator(operator)

    key, target = parse_key_and_value(value)
    return scope.none if key.blank?

    return scope.where(field_present_sql, key: key) if target.nil?

    scope.where(field_matches_sql(operator), key: key, value: bind_value(operator, target))
  end

  private
    # Split on the FIRST separator only: a value may legitimately contain "=" (a base64
    # reference, for instance), while a JSON key realistically does not.
    def parse_key_and_value(value)
      raw = value.to_s.strip
      return [ nil, nil ] if raw.blank?

      key, separator, target = raw.partition(KEY_VALUE_SEPARATOR)

      # No separator at all means "just check the field is there".
      return [ key.strip, nil ] if separator.blank?

      [ key.strip, target.strip ]
    end

    def bind_value(operator, target)
      return target unless operator == "like"

      "%#{ActiveRecord::Base.sanitize_sql_like(target)}%"
    end

    # jsonb_exists, not `->> :key IS NOT NULL`: ->> yields SQL NULL both for a missing key
    # and for one whose value is JSON null, so the latter would be reported as absent and
    # break the "field exists, whatever its value" contract above.
    def field_present_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM jsonb_path_query(transactions.extra, 'strict $.**') AS node
          WHERE jsonb_typeof(node) = 'object'
            AND jsonb_exists(node, :key)
        )
      SQL
    end

    # The comparison operator is chosen from the whitelist in #operators, never
    # interpolated from user input; the key and value are bound.
    def field_matches_sql(operator)
      comparison = operator == "like" ? "ILIKE" : "="

      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM jsonb_path_query(transactions.extra, 'strict $.**') AS node
          WHERE jsonb_typeof(node) = 'object'
            AND node ->> :key #{comparison} :value
        )
      SQL
    end
end
