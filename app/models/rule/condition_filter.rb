class Rule::ConditionFilter
  UnsupportedOperatorError = Class.new(StandardError)

  TYPES = [ "text", "number", "select" ]

  OPERATORS_MAP = {
    "text" => [ [ "Contains", "like" ], [ "Equal to", "=" ], [ "Is empty", "is_null" ] ],
    "number" => [ [ "Greater than", ">" ], [ "Greater or equal to", ">=" ], [ "Less than", "<" ], [ "Less than or equal to", "<=" ], [ "Is equal to", "=" ] ],
    "select" => [ [ "Equal to", "=" ], [ "Is empty", "is_null" ] ]
  }

  def initialize(rule)
    @rule = rule
  end

  def type
    "text"
  end

  def number_step
    family_currency = Money::Currency.new(family.currency)
    family_currency.step
  end

  def key
    self.class.name.demodulize.underscore
  end

  def label
    key.humanize
  end

  def options
    nil
  end

  def operators
    OPERATORS_MAP.dig(type)
  end

  # Matchers can prepare the scope with joins by implementing this method
  def prepare(scope)
    scope
  end

  # Applies the condition to the scope
  def apply(scope, operator, value)
    raise NotImplementedError, "Condition #{self.class.name} must implement #apply"
  end

  def as_json
    {
      type: type,
      key: key,
      label: label,
      operators: operators,
      options: options,
      number_step: number_step
    }
  end

  private
    attr_reader :rule

    def family
      rule.family
    end

    def build_sanitized_where_condition(field, operator, value)
      if operator == "is_null"
        ActiveRecord::Base.sanitize_sql_for_conditions(
          "#{field} #{sanitize_operator(operator)}"
        )
      else
        normalized_value = normalize_value(value)
        normalized_field = normalize_field(field)
        sanitized_value = operator == "like" ? "%#{ActiveRecord::Base.sanitize_sql_like(normalized_value)}%" : normalized_value

        ActiveRecord::Base.sanitize_sql_for_conditions([
          "#{normalized_field} #{sanitize_operator(operator)} ?",
          sanitized_value
        ])
      end
    end

    def sanitize_operator(operator)
      raise UnsupportedOperatorError, "Unsupported operator: #{operator} for type: #{type}" unless operators.map(&:last).include?(operator)

      case operator
      when "like"
        "ILIKE"
      when "is_null"
        "IS NULL"
      else
        operator
      end
    end

    def normalize_value(value)
      return value unless type == "text"

      value.to_s.gsub(/\s+/, " ").strip
    end

    def normalize_field(field)
      return field unless type == "text"

      "BTRIM(REGEXP_REPLACE(#{field}, '[[:space:]]+', ' ', 'g'))"
    end
end
