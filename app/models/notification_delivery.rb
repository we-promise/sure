class NotificationDelivery < ApplicationRecord
  belongs_to :rule
  # The association is named :transaction_record rather than :transaction because
  # ActiveRecord refuses to define a :transaction association (it would clash with
  # the built-in #transaction method). The underlying column is still
  # transaction_id; dedup keys on that column directly.
  belongs_to :transaction_record, class_name: "Transaction", foreign_key: :transaction_id

  # Records deliveries race-safely in a single insert_all keyed on the unique
  # (rule_id, transaction_id) index, and returns ONLY the transaction_ids this
  # call actually inserted. Rows that already exist are skipped by the unique
  # index (no raise) and excluded from the result, so two concurrent runs that
  # observe the same candidates each get a disjoint set back — the caller can
  # enqueue off the return value without re-notifying already-delivered ids.
  #
  # Dedup keys on the DB row id (`transaction_id`), NOT provider identity: a
  # re-ingested transaction gets a new id and may notify again. This is accepted
  # as benign (see Rule::ActionExecutor::SendEmailNotification).
  def self.record_for(rule_id:, transaction_ids:)
    return [] if transaction_ids.blank?

    now = Time.current
    rows = transaction_ids.map do |transaction_id|
      { rule_id: rule_id, transaction_id: transaction_id, created_at: now, updated_at: now }
    end

    result = insert_all(
      rows,
      unique_by: :index_notification_deliveries_on_rule_and_transaction,
      returning: [ :transaction_id ]
    )

    result.rows.flatten
  end
end
