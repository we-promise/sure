class Rule::Condition < ApplicationRecord
  SUPPORTED_CONDITION_TYPES = (Rule::Registry::TransactionResource.condition_filter_keys + [ "compound" ]).freeze

  LEGACY_CONDITION_TYPE_ALIASES = {
    "name" => "transaction_name"
  }.freeze

  belongs_to :rule, touch: true, optional: -> { where.not(parent_id: nil) }
  belongs_to :parent, class_name: "Rule::Condition", optional: true, inverse_of: :sub_conditions

  has_many :sub_conditions, -> { order(:created_at, :id) }, class_name: "Rule::Condition", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent

  before_validation :normalize_legacy_condition_type

  validates :condition_type, presence: true, inclusion: { in: SUPPORTED_CONDITION_TYPES, allow_blank: true },
    if: -> { condition_type.to_s.valid_encoding? }
  validates :operator, presence: true, if: -> { operator.to_s.valid_encoding? }
  validates :value, presence: true,
    unless: -> { compound? || Rule::ConditionFilter::VALUELESS_OPERATORS.include?(operator) },
    if: -> { value.to_s.valid_encoding? }
  validates_with DatabaseTextValidator, attributes: %i[condition_type operator value]

  validate :regex_value_is_safe, if: :regex_value_changed?

  accepts_nested_attributes_for :sub_conditions, allow_destroy: true

  # We don't store rule_id on sub_conditions, so "walk up" to the parent rule
  def rule
    parent&.rule || super
  end

  def compound?
    condition_type == "compound"
  end

  # Whether saving this condition would change which resources it matches: it is
  # new, it is about to be destroyed, its type, operator or value is changing, or
  # one of its sub-conditions is. Reads only what is in memory, which is where
  # nested attributes put pending changes, so it costs no query.
  #
  # The edit form resubmits every condition with its current values; those are
  # not changes. Nor is a value moving between nil and "": the form sends a
  # valueless condition's hidden value field back as "" where an import stored
  # nil, and no filter reads a blank value (validation requires one for every
  # operator that does).
  def match_criteria_changing?
    return true if new_record? || marked_for_destruction?
    return true if will_save_change_to_condition_type? || will_save_change_to_operator?
    return true if will_save_change_to_value? && value_in_database.presence != value.presence

    association(:sub_conditions).target.any?(&:match_criteria_changing?)
  end

  def regex?
    Rule::ConditionFilter::REGEX_OPERATORS.include?(operator)
  end

  # True when this condition, or any condition nested in it, matches a pattern.
  def uses_regex?
    compound? ? sub_conditions.any?(&:regex?) : regex?
  end

  # Probing costs a database round trip, so an untouched condition (a rule being
  # toggled active, say) is not probed again.
  def regex_value_changed?
    regex? && (new_record? || will_save_change_to_value? || will_save_change_to_operator?)
  end

  def apply(scope)
    if compound?
      build_compound_scope(scope)
    else
      filter.apply(scope, operator, value)
    end
  end

  def prepare(scope)
    if compound?
      sub_conditions.reduce(scope) { |s, sub| sub.prepare(s) }
    else
      filter.prepare(scope)
    end
  end

  def value_display
    if value.present?
      if options
        options.find { |option| option.last == value }&.first
      else
        value
      end
    else
      ""
    end
  end

  def options
    filter.options
  end

  def operators
    filter.operators
  end

  def filter
    rule.registry.get_filter!(condition_type)
  rescue Rule::Registry::UnsupportedConditionError
    Rule::ConditionFilter::Unsupported.new(rule, condition_type)
  end

  private
    # A blank value is already reported by the presence validation, and one the
    # database will not store (a null byte, malformed UTF-8) by
    # DatabaseTextValidator. Neither can be probed: the driver refuses to send it.
    def regex_value_is_safe
      return unless DatabaseTextValidator.acceptable?(value)
      return if value.blank?

      error = Rule::SafeRegex.error_for(value)
      return if error.nil?

      errors.add(:value, :"regex_#{error}", count: Rule::SafeRegex::MAX_LENGTH)
    end

    def normalize_legacy_condition_type
      return unless condition_type.is_a?(String) && condition_type.valid_encoding?
      return if condition_type.blank?

      normalized = LEGACY_CONDITION_TYPE_ALIASES[condition_type]
      self.condition_type = normalized if normalized
    end

    def build_compound_scope(scope)
      if operator == "or"
        combined_scope = sub_conditions
          .map { |sub| sub.apply(scope) }
          .reduce { |acc, s| acc.or(s) }

        combined_scope || scope
      else
        sub_conditions.reduce(scope) { |s, sub| sub.apply(s) }
      end
    end
end
