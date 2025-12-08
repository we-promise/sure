class Rule < ApplicationRecord
  UnsupportedResourceTypeError = Class.new(StandardError)

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name

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
    matching_resources_scope.count
  end

  def apply(ignore_attribute_locks: false, rule_run: nil)
    total_modified = 0
    total_async_jobs = 0
    has_async = false

    actions.each do |action|
      result = action.apply(matching_resources_scope, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

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
    return "No conditions" if conditions.none?

    first_condition = conditions.first
    if first_condition.compound? && first_condition.sub_conditions.any?
      first_sub_condition = first_condition.sub_conditions.first
      "If #{first_sub_condition.filter.label.downcase} #{first_sub_condition.operator} #{first_sub_condition.value_display}"
    else
      "If #{first_condition.filter.label.downcase} #{first_condition.operator} #{first_condition.value_display}"
    end
  end

  private
    def matching_resources_scope
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

    def min_actions
      return if new_record? && actions.empty?

      if actions.reject(&:marked_for_destruction?).empty?
        errors.add(:base, "must have at least one action")
      end
    end

    def no_duplicate_actions
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, "Rule cannot have duplicate actions #{action_types.inspect}") if action_types.uniq.count != action_types.count
    end

    # Validation: To keep rules simple and easy to understand, we don't allow nested compound conditions.
    def no_nested_compound_conditions
      return true if conditions.none? { |condition| condition.compound? }

      conditions.each do |condition|
        if condition.compound?
          if condition.sub_conditions.any? { |sub_condition| sub_condition.compound? }
            errors.add(:base, "Compound conditions cannot be nested")
          end
        end
      end
    end

    def normalize_name
      self.name = nil if name.is_a?(String) && name.strip.empty?
    end
end
