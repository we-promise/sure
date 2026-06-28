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
  after_create_commit :seed_notification_baseline

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  def options
    executor.options
  end

  def value_display
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
    def seed_notification_baseline
      return unless action_type == "send_email_notification"

      NotificationDelivery.record_for(
        rule_id: rule_id,
        transaction_ids: rule.matching_transaction_ids
      )
    end
end
