class Rule::ActionExecutor::SendEmailNotification < Rule::ActionExecutor
  def label
    "Send email notification"
  end

  # rule_run is accepted for interface compatibility but unused: the digest email
  # is fire-and-forget and is not tracked as part of RuleRun accounting.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    candidate_ids = transaction_scope.pluck(:id)

    # record_for atomically inserts and returns ONLY the ids this run actually
    # claimed. We enqueue off that result (not the pre-insert candidate list) so
    # two concurrent runs over the same matches never enqueue duplicate digests:
    # whichever loses the unique-index race gets those ids back as empty.
    #
    # Recording is the dedup boundary, since re-syncs re-apply every active rule
    # to all in-window matches (not just newly ingested transactions). If the
    # process crashes after recording but before delivery, the next run suppresses
    # these ids rather than re-sending — we would rather miss a digest than spam.
    new_transaction_ids = NotificationDelivery.record_for(rule_id: rule.id, transaction_ids: candidate_ids)

    return 0 if new_transaction_ids.empty?

    RuleEmailNotificationJob.perform_later(rule.id, new_transaction_ids)

    # Synchronous count of newly-notified transactions. The email itself is
    # delivered out-of-band by the job and is not part of RuleRun accounting.
    new_transaction_ids.size
  end
end
