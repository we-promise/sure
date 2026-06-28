class Rule::ActionExecutor::SendEmailNotification < Rule::ActionExecutor
  def label
    "Send email notification"
  end

  # rule_run is accepted for interface compatibility but unused: the digest email
  # is fire-and-forget and is not tracked as part of RuleRun accounting.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    candidate_ids = transaction_scope.pluck(:id)
    new_transaction_ids = NotificationDelivery.unnotified_ids(rule_id: rule.id, transaction_ids: candidate_ids)

    return 0 if new_transaction_ids.empty?

    # Record BEFORE enqueueing. Fail-safe ordering: if recording succeeds but the
    # process crashes before/while sending, the next run suppresses these ids
    # rather than re-sending. We would rather miss a digest than spam. Dedup is
    # the ONLY thing preventing re-sends, since re-syncs re-apply every active
    # rule to all in-window matches (not just newly ingested transactions).
    NotificationDelivery.record_for(rule_id: rule.id, transaction_ids: new_transaction_ids)

    RuleEmailNotificationJob.perform_later(rule.id, new_transaction_ids)

    # Synchronous count of newly-notified transactions. The email itself is
    # delivered out-of-band by the job and is not part of RuleRun accounting.
    new_transaction_ids.size
  end
end
