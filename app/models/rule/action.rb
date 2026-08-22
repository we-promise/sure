class Rule::Action < ApplicationRecord
  belongs_to :rule, touch: true

  # Virtual attribute for the split_transaction form: `value` is a single string column, so the
  # split builder UI posts real, individually-named fields here instead of driving a JSON blob
  # through custom JS. build_split_value assembles them into `value` before validation runs.
  # Each row carries its own "type" (fixed or percentage) rather than the action having a single
  # mode — see Rule::ActionExecutor::SplitTransaction for how the two types combine.
  attr_accessor :split_rows

  validates :action_type, presence: true
  before_validation :build_split_value, if: -> { action_type == "split_transaction" && split_rows.present? }
  validate :split_config_valid, if: -> { action_type == "split_transaction" }

  # Pre-seed (watermark): when a send_email_notification action is created — on a
  # new rule OR added to an existing one — record all currently-matching
  # transactions as already-delivered WITHOUT sending, so the rule only ever
  # emails about transactions that appear AFTER the action exists.
  #
  # Uses after_create_commit (not after_create): nested children persist before
  # the parent rule commits, and the pre-seed reads the rule's conditions, which
  # must be committed first.
  #
  # after_update_commit covers the edit flow: the action_type select is editable
  # for persisted actions (see rules_controller#rule_params), so an existing
  # action can be CHANGED to send_email_notification. Without re-seeding, the
  # next apply/sync would email every historical match. Guard on the type change
  # so we only watermark when an action actually becomes email-notify.
  after_create_commit :seed_notification_baseline
  after_update_commit :seed_notification_baseline, if: :saved_change_to_action_type?

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  def options
    executor.options
  end

  def value_display
    custom_display = executor.value_display(value)
    return custom_display if custom_display.present?

    if value.present?
      if options
        options.find { |option| option.last == value }&.first
      else
        ""
      end
    else
      ""
    end
  end

  def executor
    rule.registry.get_executor!(action_type)
  end

  private
    def build_split_value
      rows = split_rows.respond_to?(:values) ? split_rows.values : Array(split_rows)
      splits = rows.map do |row|
        {
          type: row[:type],
          name: row[:name],
          share: row[:share],
          category_id: row[:category_id].presence,
          merchant_id: row[:merchant_id].presence,
          tag_ids: Array(row[:tag_ids]).reject(&:blank?)
        }
      end

      self.value = { splits: splits }.to_json
    end

    def split_config_valid
      config_errors = Rule::ActionExecutor::SplitTransaction.config_errors(value, family: rule.family)
      config_errors.each do |key, options|
        errors.add(:value, key, **options)
      end

      return unless config_errors.empty?

      config = Rule::ActionExecutor::SplitTransaction.parse_config(value)
      return if Rule::ActionExecutor::SplitTransaction.has_percentage_split?(config)

      # Pure fixed splits (no percentage row to absorb whatever's left) only make sense if every
      # matching transaction has the same total, since there's nothing dynamic to cover a
      # mismatch — require an exact "Amount =" condition whose value the fixed shares sum to.
      exact_amount = exact_amount_condition_value
      if exact_amount.nil?
        errors.add(:value, :fixed_requires_exact_amount_condition)
      else
        total_share = config["splits"].sum { |split| BigDecimal(split["share"].to_s) }
        if total_share != exact_amount
          errors.add(:value, :fixed_shares_must_equal_condition_amount, amount: exact_amount)
        end
      end
    end

    # Fixed-amount splits only make sense if every matching transaction has the same total —
    # otherwise the configured shares can never sum correctly for most matches (rule.apply
    # would just silently skip them one by one). Require an exact "Amount =" condition, ANDed
    # in (an "any"/OR compound doesn't guarantee it for every match), and return its numeric
    # value so callers can also check the shares actually sum to it. Returns nil if no such
    # condition exists.
    def exact_amount_condition_value(conditions = rule.conditions)
      conditions.reject(&:marked_for_destruction?).each do |condition|
        if condition.compound?
          next unless condition.operator == "and"
          found = exact_amount_condition_value(condition.sub_conditions)
          return found if found
        elsif condition.condition_type == "transaction_amount" && condition.operator == "="
          parsed = parse_condition_amount(condition.value)
          return parsed if parsed
        end
      end

      nil
    end

    def parse_condition_amount(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def seed_notification_baseline
      return unless action_type == "send_email_notification"

      NotificationDelivery.record_for(
        rule_id: rule_id,
        transaction_ids: rule.matching_transaction_ids
      )
    end
end
