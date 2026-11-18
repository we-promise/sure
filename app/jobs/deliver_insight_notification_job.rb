class DeliverInsightNotificationJob < ApplicationJob
  queue_as :scheduled
  # The persisted delivery owns the total budget; ActiveJob only schedules
  # backoff. Sidekiq must not start a separate retry chain.
  sidekiq_options retry: false

  retry_on Apns::Client::TransientError, wait: :polynomially_longer, attempts: PushDelivery::MAX_PROVIDER_ATTEMPTS
  discard_on ActiveRecord::RecordNotFound

  def perform(push_delivery_id: nil, insight_id: nil, push_subscription_id: nil)
    delivery =
      if push_delivery_id
        PushDelivery.find(push_delivery_id)
      else
        # Queued before the ledger existed. Synthesize the row this send needs
        # so in-flight jobs survive the deploy instead of dying on an
        # incompatible signature; the claim re-checks every eligibility rule.
        subscription = PushSubscription.find(push_subscription_id)
        insight = Insight.find(insight_id)
        PushDelivery.for_subscription(subscription, insight)
      end
    return unless delivery

    attempt = delivery.claim_attempt!
    return unless attempt

    subscription = delivery.subscription
    result = PushSubscription::Delivery.new(subscription).call do |client|
      client.deliver(**delivery.payload)
    end
    if result == :skipped
      # The channel could not attempt (for example the client went unavailable
      # between claim and deliver); release the reservation instead of
      # recording an outcome the provider never gave.
      delivery.release_attempt!(attempt)
    else
      delivery.complete_attempt!(attempt, result: result)
    end
  rescue Apns::Client::TransientError
    raise if delivery.retry_attempt!(attempt)
  end
end
