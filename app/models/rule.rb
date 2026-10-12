class Rule < ApplicationRecord
  UnsupportedResourceTypeError = Class.new(StandardError)

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name

  validates :resource_type, presence: true, if: -> { resource_type.to_s.valid_encoding? }
  validates :name, length: { minimum: 1 }, allow_nil: true, if: -> { name.to_s.valid_encoding? }
  validates_with DatabaseTextValidator, attributes: %i[name resource_type]
  validate :no_nested_compound_conditions

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions

  # An email rule records the transactions it already matches as delivered, so it
  # only reports what appears afterwards (see Rule::Action#seed_notification_baseline).
  # That baseline describes the match set of the conditions and effective date it
  # was taken under. An edit that changes them can bring older transactions into
  # range, and the next run would email them as new, so the baseline is taken
  # again. Active or not: Apply all runs inactive rules too, and the action's own
  # seed does not check `active` either.
  #
  # The change is noted before the update, while nested attributes still hold it
  # in memory: once autosave has run, a destroyed condition is gone from the
  # association and a saved one no longer reports a pending change.
  #
  # A condition reporting a change is then checked against the stored criteria,
  # one query, since the importers replace every condition on each re-import. An
  # identical re-import must not re-seed: that would record a match still waiting
  # for the next run as delivered, and it would never be emailed.
  #
  # after_update, not after_update_commit: it runs inside the save's transaction,
  # after the nested conditions and actions are written (it is declared after
  # accepts_nested_attributes_for, so it runs after their autosave), and reads
  # them on the same connection as saved. The new baseline commits together with
  # the edit, so nothing can see the new conditions without it, and if writing it
  # fails the edit rolls back rather than leaving a stale baseline behind.
  before_update :note_match_criteria_change
  after_update :seed_notification_baseline, if: :match_criteria_changed?

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

  # Public wrapper around the private matching scope so callers can read the
  # currently-matching transaction ids WITHOUT running executors (e.g. the
  # notification baseline pre-seed). Mirrors total_affected_resource_count,
  # which also reaches matching_resources_scope.
  def matching_transaction_ids
    matching_resources_scope.pluck(:id)
  end

  # Whether this rule's conditions currently match the given transaction.
  def matches_transaction?(transaction)
    matching_resources_scope.where(id: transaction.id).exists?
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
      transaction_ids.merge(rule.send(:matching_resources_scope).pluck(:id))
    end

    transaction_ids.size
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

    def note_match_criteria_change
      @match_criteria_changed = will_save_change_to_effective_date? ||
        (association(:conditions).target.any?(&:match_criteria_changing?) && condition_criteria_changing?)
    end

    # Whether the criteria this save leaves differ from the stored ones. The
    # importers replace every condition, so each one reads as changing even when
    # the new set holds the same criteria; only a different set re-seeds.
    #
    # Compares two signatures: the conditions as stored (one query), and the same
    # rows with this save's pending changes laid over them. Order does not count
    # (top-level conditions all apply, and a group's and/or reads its members
    # either way), and neither does nil against "" (see
    # Rule::Condition#match_criteria_changing?).
    def condition_criteria_changing?
      top_level_ids = Rule::Condition.where(rule_id: id).select(:id)
      stored = Rule::Condition.where(rule_id: id).or(Rule::Condition.where(parent_id: top_level_ids)).to_a
      stored_children = stored.group_by(&:parent_id)
      stored_top_level = stored.select { |condition| condition.rule_id == id }

      before = criteria_signature(stored_top_level) { |condition| stored_children[condition.id].to_a }
      after = criteria_signature(pending_conditions(stored_top_level, association(:conditions).target)) do |condition|
        stored_for_condition = condition.new_record? ? [] : stored_children[condition.id].to_a
        pending_conditions(stored_for_condition, condition.association(:sub_conditions).target)
      end

      before != after
    end

    # The stored conditions as this save leaves them: in-memory copies replace
    # their stored rows, new ones join, and those marked for destruction drop out.
    def pending_conditions(stored, in_memory)
      in_memory_by_id = in_memory.reject(&:new_record?).index_by(&:id)

      (stored.map { |condition| in_memory_by_id.fetch(condition.id, condition) } + in_memory.select(&:new_record?))
        .reject(&:marked_for_destruction?)
    end

    def criteria_signature(conditions, &children)
      conditions.map do |condition|
        [
          condition.condition_type.to_s,
          condition.operator.to_s,
          condition.value.presence.to_s,
          criteria_signature(children.call(condition)) { [] }
        ]
      end.sort
    end

    def match_criteria_changed?
      @match_criteria_changed == true
    end

    def seed_notification_baseline
      return unless actions.exists?(action_type: "send_email_notification")

      NotificationDelivery.record_for(rule_id: id, transaction_ids: matching_transaction_ids)
    end

    def normalize_name
      return unless name.is_a?(String)
      return unless name.valid_encoding?
      return if name.include?("\0")

      self.name = nil if name.strip.empty?
    end
end
