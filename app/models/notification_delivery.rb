class NotificationDelivery < ApplicationRecord
  belongs_to :rule
  # The association is named :transaction_record rather than :transaction because
  # ActiveRecord refuses to define a :transaction association (it would clash with
  # the built-in #transaction method). The underlying column is still
  # transaction_id; dedup keys on that column directly.
  belongs_to :transaction_record, class_name: "Transaction", foreign_key: :transaction_id

  # Returns the subset of `transaction_ids` not yet recorded as delivered for
  # this rule. Dedup keys on the DB row id (`transaction_id`), NOT provider
  # identity: a re-ingested transaction gets a new id and may notify again. This
  # is accepted as benign (see Rule::ActionExecutor::SendEmailNotification).
  def self.unnotified_ids(rule_id:, transaction_ids:)
    return [] if transaction_ids.blank?

    already_notified = where(rule_id: rule_id, transaction_id: transaction_ids).pluck(:transaction_id)
    transaction_ids - already_notified
  end

  # Records deliveries race-safely in a single insert_all keyed on the unique
  # (rule_id, transaction_id) index. Rows that already exist are skipped (no
  # raise), so concurrent runs neither duplicate nor blow up.
  def self.record_for(rule_id:, transaction_ids:)
    return if transaction_ids.blank?

    now = Time.current
    rows = transaction_ids.map do |transaction_id|
      { rule_id: rule_id, transaction_id: transaction_id, created_at: now, updated_at: now }
    end

    insert_all(rows, unique_by: :index_notification_deliveries_on_rule_and_transaction)
  end
end
