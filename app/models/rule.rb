class Rule < ApplicationRecord
  UnsupportedResourceTypeError = Class.new(StandardError)

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name
  before_create :assign_next_position

  # Rules run top to bottom. created_at breaks ties, e.g. for rules created at
  # the same moment before anyone reordered them.
  scope :ordered, -> { order(:position, :created_at, :id) }

  validates :resource_type, presence: true
  validates :name, length: { minimum: 1 }, allow_nil: true
  validate :no_nested_compound_conditions

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions

  def action_executors
    registry.action_executors
  end

  def condition_filters
    registry.condition_filters
  end

  def registry
    @registry ||= case resource_type
    when "transaction"
      Rule::Registry::TransactionResource.new(self)
    else
      raise UnsupportedResourceTypeError, "Unsupported resource type: #{resource_type}"
    end
  end

  def affected_resource_count
    matching_scope.count
  end

  # Reads the currently-matching transaction ids WITHOUT running executors
  # (e.g. the notification baseline pre-seed).
  def matching_transaction_ids
    matching_scope.pluck(:id)
  end

  # Sets the run order of all rules of a family. ordered_ids must list every
  # rule of the family exactly once, so a stale page (a rule added or deleted
  # meanwhile) cannot leave rules with clashing or missing positions.
  def self.update_positions!(family, ordered_ids)
    ordered_ids = Array(ordered_ids).map(&:to_s)
    family_rule_ids = family.rules.pluck(:id)

    unless ordered_ids.size == family_rule_ids.size && ordered_ids.sort == family_rule_ids.sort
      raise ArgumentError, "ordered_ids must list every rule of the family exactly once"
    end

    return if ordered_ids.empty?

    encoder = PG::TextEncoder::Array.new
    sql = sanitize_sql_array([ <<~SQL.squish, encoder.encode(ordered_ids), encoder.encode((1..ordered_ids.size).to_a), family.id ])
      UPDATE rules SET position = new_positions.position
      FROM unnest(?::uuid[], ?::integer[]) AS new_positions(id, position)
      WHERE rules.id = new_positions.id AND rules.family_id = ?
    SQL
    with_connection { |connection| connection.update(sql, "Rule Update Positions") }
  end

  # Excludes transaction ids with one array parameter. where.not(id: ids) sends
  # one bind per id, which breaks beyond PostgreSQL's 65,535 bind limit when a
  # broad rule claims or stops many transactions.
  def self.excluding_transaction_ids(scope, ids)
    return scope if ids.empty?

    scope.where.not("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(ids.to_a))
  end

  # Whether this rule's conditions currently match the given transaction.
  def matches_transaction?(transaction)
    matching_scope.where(id: transaction.id).exists?
  end

  # Creates a categorization rule for the Quick Categorize Wizard.
  # Returns the saved rule, or nil if a duplicate or invalid rule already exists.
  def self.create_from_grouping(family, grouping_key, category, transaction_type: nil)
    rule = family.rules.build(name: grouping_key, resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: grouping_key)
    rule.conditions.build(condition_type: "transaction_type", operator: "=", value: transaction_type) if transaction_type.present?
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!
    rule
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Calculates total unique resources affected across multiple rules
  # This handles overlapping rules by deduplicating transaction IDs
  def self.total_affected_resource_count(rules)
    return 0 if rules.empty?

    # Collect all unique transaction IDs matched by any rule
    transaction_ids = Set.new
    rules.each do |rule|
      transaction_ids.merge(rule.matching_scope.pluck(:id))
    end

    transaction_ids.size
  end

  # scope: the transactions to act on. Rule::Runner passes the matches minus
  # transactions a rule higher up stopped. claimed_ids maps an attribute to the
  # transaction ids a rule higher up already set it for; an action leaves those
  # transactions alone ("top rule wins").
  def apply(ignore_attribute_locks: false, rule_run: nil, scope: matching_scope, claimed_ids: {})
    total_modified = 0
    total_async_jobs = 0
    has_async = false

    actions.each do |action|
      excluded_ids = action.claimed_attributes.flat_map { |attribute| claimed_ids.fetch(attribute, []).to_a }.uniq
      action_scope = Rule.excluding_transaction_ids(scope, excluded_ids)
      result = action.apply(action_scope, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

      if result.is_a?(Hash) && result[:async]
        has_async = true
        total_async_jobs += result[:jobs_count] || 0
        total_modified += result[:modified_count] || 0
      elsif result.is_a?(Integer)
        total_modified += result
      else
        # Log unexpected result type but don't fail
        Rails.logger.warn("Rule#apply: Unexpected result type from action #{action.id}: #{result.class} (value: #{result.inspect})")
      end
    end

    if has_async
      { modified_count: total_modified, async: true, jobs_count: total_async_jobs }
    else
      total_modified
    end
  end

  def apply_later(ignore_attribute_locks: false)
    RuleJob.perform_later(self, ignore_attribute_locks: ignore_attribute_locks)
  end

  def primary_condition_title
    condition = displayed_condition
    return I18n.t("rules.no_condition") if condition.blank?

    "If #{condition.filter.label.downcase} #{condition.operator} #{condition.value_display}"
  end

  def displayed_condition
    displayable_conditions.first
  end

  def additional_displayable_conditions_count
    [ displayable_conditions.size - 1, 0 ].max
  end

  def displayable_conditions
    conditions.filter_map do |condition|
      condition.compound? ? condition.sub_conditions.first : condition
    end
  end

  def matching_scope
    scope = registry.resource_scope

    # 1. Prepare the query with joins required by conditions
    conditions.each do |condition|
      scope = condition.prepare(scope)
    end

    # 2. Apply the conditions to the query
    conditions.each do |condition|
      scope = condition.apply(scope)
    end

    scope
  end

  private
    def assign_next_position
      return if position.to_i.positive?

      self.position = family.rules.maximum(:position).to_i + 1
    end

    def min_actions
      return if new_record? && !actions.empty?

      if actions.reject(&:marked_for_destruction?).empty?
        errors.add(:base, :min_actions)
      end
    end

    def no_duplicate_actions
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, :duplicate_actions, types: action_types.inspect) if action_types.uniq.count != action_types.count
    end

    # Validation: To keep rules simple and easy to understand, we don't allow nested compound conditions.
    def no_nested_compound_conditions
      return true if conditions.none? { |condition| condition.compound? }

      conditions.each do |condition|
        if condition.compound?
          if condition.sub_conditions.any? { |sub_condition| sub_condition.compound? }
            errors.add(:base, :nested_conditions)
          end
        end
      end
    end

    def normalize_name
      self.name = nil if name.is_a?(String) && name.strip.empty?
    end
end
