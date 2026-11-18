class DeliverInsightNotificationJob < ApplicationJob
  queue_as :scheduled
  # The persisted delivery owns the total budget; ActiveJob only schedules
  # backoff. Sidekiq must not start a separate retry chain.
  sidekiq_options retry: false

  retry_on Apns::Client::TransientError, wait: :polynomially_longer, attempts: PushDelivery::MAX_PROVIDER_ATTEMPTS
  discard_on ActiveRecord::RecordNotFound

  def perform(push_delivery_id:)
    delivery = PushDelivery.find(push_delivery_id)
    attempt = delivery.claim_attempt!
    return unless attempt

    subscription = delivery.subscription
    result = PushSubscription::Delivery.new(subscription).call do |client|
      client.deliver(**delivery.payload)
    end
    # A skipped result means the channel could not attempt (for example the
    # client went unavailable between claim and deliver); hand the attempt
    # back instead of recording an outcome the provider never gave.
    if result == :skipped
      delivery.retry_attempt!(attempt)
    else
      delivery.complete_attempt!(attempt, result: result == :accepted ? :accepted : :rejected)
    end
  rescue Apns::Client::TransientError
    raise if delivery.retry_attempt!(attempt)
  end
end
