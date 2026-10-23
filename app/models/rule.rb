class Rule < ApplicationRecord
  # Namespace for the per-family advisory lock around position assignment.
  POSITION_LOCK_NAMESPACE = 4013

  UnsupportedResourceTypeError = Class.new(StandardError)
  SUPPORTED_RESOURCE_TYPES = %w[transaction].freeze

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

  validates :resource_type, presence: true, if: -> { resource_type.to_s.valid_encoding? }
  # A NUL or invalid encoding is reported by DatabaseTextValidator instead.
  validates :resource_type, inclusion: { in: SUPPORTED_RESOURCE_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(resource_type) }
  validates :name, length: { minimum: 1 }, allow_nil: true, if: -> { name.to_s.valid_encoding? }
  validates_with DatabaseTextValidator, attributes: %i[name resource_type]
  validate :no_nested_compound_conditions

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions
  validate :split_is_only_action

  # Switching a rule on records the transactions it already matches as delivered,
  # so an email action only reports what appears afterwards. Rule::Action seeds the
  # same baseline when the action is created, but a rule switched off and on again
  # (by the toggle, the form, Apply or an import) would otherwise email every match
  # from before, including those from while it was off.
  #
  # The baseline also describes the match set of the conditions and effective date it
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
  after_update :seed_notification_baseline, if: :notification_baseline_out_of_date?

  # Set when this save's after_update took the baseline, or tried to and timed
  # out. Rule::Action's commit callback for an email action added in the same
  # save then skips its own, which would run the query again and, on a timeout,
  # switch off a rule that has its baseline. Reset at the start of every save.
  before_save :reset_notification_baseline_taken

  def notification_baseline_taken_in_this_save?
    @notification_baseline_taken == true
  end

  # True when the last save asked to switch the rule on, changed what it matches,
  # or gave it an email action, but the baseline query timed out, so the rule was
  # left off.
  def notification_baseline_timed_out?
    @notification_baseline_timed_out == true
  end

  # Without a baseline the next run would email every past match, so the rule
  # is switched off. Rule::Action calls this from its commit callback, on the
  # rule the save went through (the controller's), so the response can say so.
  # Recorded in the debug log, where support can see why the rule went off.
  def notification_baseline_timed_out!(error, source:)
    @notification_baseline_timed_out = true
    update_columns(active: false)
    DebugLogEntry.capture(
      category: "rule_notification",
      level: "warn",
      message: "Notification baseline timed out; rule switched off",
      source: source,
      family: family,
      metadata: { rule_id: id, rule_name: name, error_class: error.class.name, error_message: error.message }
    )
  end

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

  # Display-only: a pattern that times out reads as zero here, and the failure
  # surfaces where the rule actually runs (#apply).
  def affected_resource_count
    matching_scope.count
  rescue Rule::SafeRegex::TimeoutError
    0
  end

  # Whether the rule, as stored, has an email action. Read from the database,
  # so actions built or marked for destruction in memory do not change it. The
  # assistant reads it before replacing a rule's actions, so a replacement email
  # action keeps the baseline the old one recorded (see
  # Rule::Action#keep_notification_baseline). Each of its calls commits on its
  # own; the importers, which do not, use .ids_with_stored_email_notification_action.
  def stored_email_notification_action?
    persisted? && actions.email_notifications.exists?
  end

  # The ids of the rules in `rules` that have an email action as stored now.
  # An import writes every row in one transaction, so a rule named twice would
  # see, on its second row, the email action its first row has only just
  # written; that one is replaced before it commits and never records a
  # baseline. The importers take this before writing anything and ask it
  # instead of #stored_email_notification_action?.
  def self.ids_with_stored_email_notification_action(rules)
    rules.joins(:actions).merge(Rule::Action.email_notifications).distinct.pluck(:id).to_set
  end

  # Reads the currently-matching transaction ids WITHOUT running executors
  # (e.g. the notification baseline pre-seed).
  def matching_transaction_ids
    matching_scope.pluck(:id)
  end

  # Holds the family's rule positions until the transaction ends. with_connection
  # is the transaction's own connection and isn't leased to the thread for good.
  def self.lock_positions!(family)
    with_connection do |connection|
      connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", POSITION_LOCK_NAMESPACE, family.id.to_s ]))
    end
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
  #
  # A pattern that times out matches nothing here, as it does when the rule runs:
  # the rule cannot categorize the transaction, so the prompt is still offered.
  def matches_transaction?(transaction)
    matching_scope(only_id: transaction.id).exists?
  rescue Rule::SafeRegex::TimeoutError
    false
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
    rescue Rule::SafeRegex::TimeoutError
      next
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

  # `only_id` narrows the match to one resource inside the query itself, so a
  # check on a single transaction runs any pattern on that row alone rather
  # than on the whole family.
  def matching_scope(only_id: nil)
    scope = registry.resource_scope
    scope = scope.where(id: only_id) if only_id

    # 1. Prepare the query with joins required by conditions
    conditions.each do |condition|
      scope = condition.prepare(scope)
    end

    # 2. Apply the conditions to the query
    conditions.each do |condition|
      scope = condition.apply(scope)
    end

    # A pattern is the one condition whose cost the database cannot bound by
    # itself, so its matches are resolved here, under a statement timeout, and
    # the scope returned is those ids. Every reader gets the timeout, and a
    # caller such as Rule::Runner sees it as this rule failing.
    return scope unless conditions.any?(&:uses_regex?)

    scope_for_transaction_ids(Rule::SafeRegex.with_timeout { scope.pluck(:id) })
  end

  private
    # Serialized per family with a transaction-scoped advisory lock: without
    # it, two rules created at the same time both read the same MAX(position)
    # and share a position, so their run order would silently fall back to
    # the created_at/id tie-break. before_create runs inside the save
    # transaction, so the lock is held until the new row is committed.
    def assign_next_position
      return if position.to_i.positive?

      self.class.lock_positions!(family)
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

    # Actions after a split find the parent hidden, and actions before it change only the
    # hidden parent, so a split rule can't usefully do anything else.
    def split_is_only_action
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, :split_not_alone) if action_types.include?("split_transaction") && action_types.size > 1
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

    def notification_baseline_out_of_date?
      switched_on? || match_criteria_changed?
    end

    def switched_on?
      saved_change_to_active?(from: false, to: true)
    end

    def seed_notification_baseline
      @notification_baseline_timed_out = false
      return unless actions.email_notifications.exists?

      @notification_baseline_taken = true
      NotificationDelivery.record_for(rule_id: id, transaction_ids: matching_transaction_ids)
    rescue Rule::SafeRegex::TimeoutError => e
      # As in Rule::Action#seed_notification_baseline: without a baseline the next
      # run would email every past match, so the rule stays off. The timed-out query
      # ran in its own savepoint, so the rest of the save still commits.
      notification_baseline_timed_out!(e, source: self.class.name)
    end

    def reset_notification_baseline_taken
      @notification_baseline_taken = false
    end

    def normalize_name
      return unless name.is_a?(String)
      return unless name.valid_encoding?
      return if name.include?("\0")

      self.name = nil if name.strip.empty?
    end
end
