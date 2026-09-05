class Rule::Action < ApplicationRecord
  belongs_to :rule, touch: true

  validates :action_type, presence: true

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

  # Accepts an Array (e.g. from a multi-select tag input) and stores it as a
  # comma-separated string in the existing `value` column, so multi-value
  # actions don't require a schema change. A single scalar value round-trips
  # unchanged, which keeps existing single-value rows backward compatible.
  def value=(val)
    val = val.reject(&:blank?).join(",") if val.is_a?(Array)
    super(val)
  end

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: execution_value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  def options
    executor.options
  end

  def value_display
    return "" if value.blank? || options.blank?

    Array(execution_value).filter_map { |v| options.find { |option| option.last == v }&.first }.join(", ")
  end

  def executor
    rule.registry.get_executor!(action_type)
  end

  private
    def execution_value
      executor.type == "multi_select" ? value.to_s.split(",") : value
    end

    def seed_notification_baseline
      return unless action_type == "send_email_notification"

      NotificationDelivery.record_for(
        rule_id: rule_id,
        transaction_ids: rule.matching_transaction_ids
      )
    end
end
