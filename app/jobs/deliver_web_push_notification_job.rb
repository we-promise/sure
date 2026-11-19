class DeliverWebPushNotificationJob < ApplicationJob
  queue_as :high_priority
  # The persisted delivery owns the total budget; ActiveJob only schedules
  # backoff. Sidekiq must not start a separate retry chain.
  sidekiq_options retry: false

  retry_on WebPush::Client::TransientError, wait: :polynomially_longer, attempts: PushDelivery::MAX_PROVIDER_ATTEMPTS
  discard_on ActiveRecord::RecordNotFound

  def perform(push_delivery_id:)
    delivery = PushDelivery.find(push_delivery_id)
    attempt = delivery.claim_attempt!
    return unless attempt

    subscription = delivery.subscription
    result = WebPush::Client.new.deliver(subscription: subscription, payload: delivery.payload)
    delivery.complete_attempt!(attempt, result: result, subscription_updated_at: subscription.updated_at)
  rescue WebPush::Client::TransientError
    raise if delivery.retry_attempt!(attempt)
  end
end
