class Rule < ApplicationRecord
  # Namespace for the per-family advisory lock around position assignment.
  POSITION_LOCK_NAMESPACE = 4013

  UnsupportedResourceTypeError = Class.new(StandardError)

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  # Re-watermark email notifications when an edit changes which transactions the
  # rule matches (its conditions or its effective date). Rule::Action only seeds
  # the baseline when an action becomes send_email_notification, so without this
  # the next run would email every older transaction the edited rule now matches.
  #
  # Every update assigns the flag in before_update, and only the after_update of
  # that same save reads it. Declared right below accepts_nested_attributes_for,
  # that after_update runs once the nested conditions and actions are saved,
  # inside the save's transaction, so a rolled back edit takes its baseline rows
  # with it.
  before_update :detect_matching_scope_change
  after_update :reseed_notification_baseline, if: -> { @reseed_notification_baseline }

  before_validation :normalize_name
  before_create :assign_next_position

  # Rules run top to bottom. created_at breaks ties, e.g. for rules created at
  # the same moment before anyone reordered them.
  scope :ordered, -> { order(:position, :created_at, :id) }

  validates :resource_type, presence: true, if: -> { resource_type.to_s.valid_encoding? }
  validates :name, length: { minimum: 1 }, allow_nil: true, if: -> { name.to_s.valid_encoding? }
  validates_with DatabaseTextValidator, attributes: %i[name resource_type]
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

  # Records every transaction the rule matches now as already delivered, without
  # sending, so a send_email_notification action only emails about transactions
  # that start matching afterwards. The conditions are read again from the
  # database, so the ones a save just added or removed count, whichever callback
  # (the rule's or an action's) seeds.
  def seed_notification_baseline
    conditions.reset
    NotificationDelivery.record_for(rule_id: id, transaction_ids: matching_transaction_ids)
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

  # Active rules that run before this one. "Apply rule" runs them first, so
  # the result matches the full run.
  def active_rules_above
    ordered_ids = family.rules.ordered.pluck(:id)
    above_ids = ordered_ids.take_while { |id| id != self.id }
    family.rules.where(id: above_ids, active: true).ordered
  end

  # The given transactions without re-checking the conditions, so they stay
  # the same set while the actions change the fields the conditions read.
  def scope_for_transaction_ids(ids)
    registry.resource_scope.where("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(ids.to_a))
  end

  # Whether this rule's conditions currently match the given transaction.
  def matches_transaction?(transaction)
    matching_scope.where(id: transaction.id).exists?
  end

  # The transactions this rule currently matches, as a relation (e.g. for the
  # assistant's rule preview, which counts and samples them).
  def matching_resources
    matching_scope
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
    # Serialized per family with a transaction-scoped advisory lock: without
    # it, two rules created at the same time both read the same MAX(position)
    # and share a position, so their run order would silently fall back to
    # the created_at/id tie-break. before_create runs inside the save
    # transaction, so the lock is held until the new row is committed.
    def assign_next_position
      return if position.to_i.positive?

      self.class.connection.execute(
        self.class.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", POSITION_LOCK_NAMESPACE, family_id.to_s ])
      )
      self.position = family.rules.maximum(:position).to_i + 1
    end

    def detect_matching_scope_change
      @reseed_notification_baseline = (will_save_change_to_effective_date? || conditions_changed?(conditions)) &&
        reseeds_for_email_actions?
    end

    # The baseline is the rule's (record_for takes the rule_id), so one seed
    # covers every email action. An action created or switched to
    # send_email_notification in this save seeds it from its own commit
    # callback, so the rule re-seeds only when it has an email action and none
    # of them seeds itself. before_update runs before the nested actions are
    # saved, so new_record? and will_save_change_to_action_type? still see what
    # this save does to them.
    def reseeds_for_email_actions?
      email_actions = actions.select do |action|
        action.action_type == "send_email_notification" && !action.marked_for_destruction?
      end
      email_actions.any? && email_actions.none? { |action| action.new_record? || action.will_save_change_to_action_type? }
    end

    def conditions_changed?(association)
      return false unless association.loaded?

      association.target.any? do |condition|
        condition.new_record? || condition.marked_for_destruction? || condition.changed? ||
          conditions_changed?(condition.sub_conditions)
      end
    end

    def reseed_notification_baseline
      @reseed_notification_baseline = false
      seed_notification_baseline
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
      return unless name.is_a?(String)
      return unless name.valid_encoding?
      return if name.include?("\0")

      self.name = nil if name.strip.empty?
    end
end
