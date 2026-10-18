class Rule::Action < ApplicationRecord
  # The action_type of the "Send email notification" action: the key of
  # Rule::ActionExecutor::SendEmailNotification, which is derived from its class
  # name. Rule::ActionTest checks the two agree.
  EMAIL_NOTIFICATION = "send_email_notification"

  belongs_to :rule, touch: true

  SUPPORTED_ACTION_TYPES = Rule::Registry::TransactionResource.action_executor_keys.freeze

  scope :email_notifications, -> { where(action_type: EMAIL_NOTIFICATION) }

  validates :action_type, presence: true, if: -> { action_type.to_s.valid_encoding? }
  # A NUL or invalid encoding is reported by DatabaseTextValidator instead.
  validates :action_type, inclusion: { in: SUPPORTED_ACTION_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(action_type) }
  validates_with DatabaseTextValidator, attributes: %i[action_type value]

  # Pre-seed (watermark): when a send_email_notification action is created — on a
  # new rule OR added to an existing one — record all currently-matching
  # transactions as already-delivered WITHOUT sending, so the rule only ever
  # emails about transactions that appear AFTER the action exists.
  #
  # Uses after_commit (not after_save): nested children persist before the
  # parent rule commits, and the pre-seed reads the rule's conditions, which
  # must be committed first.
  #
  # The update event covers the edit flow: the action_type select is editable
  # for persisted actions (see rules_controller#rule_params), so an existing
  # action can be CHANGED to send_email_notification. Without re-seeding, the
  # next apply/sync would email every historical match. Guard on the type change
  # so we only watermark when an action actually becomes email-notify; on create
  # the type changes from nil, so the same guard admits every new action.
  #
  # One callback for both events: after_create_commit and after_update_commit
  # naming the same method would leave only the last one registered.
  after_commit :seed_notification_baseline, on: %i[create update], if: :saved_change_to_action_type?

  # Set by the importers and the assistant's update_rule on an email action that
  # replaces one the rule already had. The rule's baseline is still recorded
  # under its id, so taking it again would mark a match still waiting for the
  # next run as delivered.
  attr_accessor :keep_notification_baseline

  # Accepts an Array (e.g. from a multi-select tag input) and stores it as a
  # comma-separated string in the existing `value` column, so multi-value
  # actions don't require a schema change. A single scalar value round-trips
  # unchanged, which keeps existing single-value rows backward compatible.
  def value=(val)
    if val.is_a?(Array)
      val = val.reject do |item|
        next false if item.is_a?(String) && !item.valid_encoding?

        item.blank?
      end.join(",")
    end
    super(val)
  end

  # Encodes a list of tag (or other) names as a single comma-separated string
  # for the portable `value`/CSV-import representation, CSV-quoting any name
  # that itself contains a comma (e.g. "Food, Dining") so it round-trips as
  # one name instead of being split into two on import.
  def self.encode_multi_value_names(names)
    CSV.generate_line(names, row_sep: "")
  end

  # Inverse of .encode_multi_value_names. Also accepts a plain unquoted
  # comma-separated string (the format used before quoting was introduced),
  # which CSV parses the same way as long as no name contains a comma.
  def self.decode_multi_value_names(str)
    CSV.parse_line(str.to_s) || []
  end

  def apply(resource_scope, ignore_attribute_locks: false, rule_run: nil)
    executor.execute(resource_scope, value: execution_value, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run) || 0
  end

  def options
    executor.options
  end

  def claimed_attributes
    executor.claimed_attributes
  end

  def reserves_claimed_attributes?
    executor.reserves_claimed_attributes? && executor.actionable?(value)
  end

  def value_display
    return "" if value.blank?

    cached_options = options
    return "" if cached_options.blank?

    labels_by_id = cached_options.to_h { |label, id| [ id.to_s, label ] }
    Array(execution_value).filter_map { |v| labels_by_id[v] }.join(", ")
  end

  def executor
    rule.registry.get_executor!(action_type)
  end

  def email_notification?
    action_type == EMAIL_NOTIFICATION
  end

  private
    def execution_value
      executor.type == "multi_select" ? value.to_s.split(",") : value
    end

    def seed_notification_baseline
      return unless email_notification?
      return if keep_notification_baseline

      NotificationDelivery.record_for(
        rule_id: rule_id,
        transaction_ids: rule.matching_transaction_ids
      )
    end
end
