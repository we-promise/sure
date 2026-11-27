# The push ledger's outbox sweep. Runs on its own schedule so a failed enqueue
# or an abandoned claim waits one PushDelivery::CLAIM_TIMEOUT, not until the
# next insight generation.
class RecoverPushDeliveriesJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    PushDelivery.recoverable.find_each(&:recover!)
  end
end
