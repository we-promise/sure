class DeliverWebPushNotificationJob < ApplicationJob
  queue_as :scheduled
  # ActiveJob owns the bounded retries; Sidekiq must not start another retry
  # sequence after the fifth failed provider attempt.
  sidekiq_options retry: false

  retry_on WebPush::Client::TransientError, wait: :polynomially_longer, attempts: 5 do |job, _error|
    WebPushDelivery.find_by(id: job.arguments.first[:web_push_delivery_id])&.update!(status: :failed)
  end
  discard_on ActiveRecord::RecordNotFound

  def self.enqueue_for(insight)
    return unless WebPush::Client.configured? && insight.active?

    WebPushSubscription.joins(:user).where(users: { family_id: insight.family_id, active: true })
      .includes(:user, :session).find_each do |subscription|
      next unless subscription.eligible_for?(insight)
      delivery = WebPushDelivery.for_insight(subscription, insight)
      next unless delivery.previously_new_record? || delivery.status_enqueue_failed?
      delivery.enqueue!
    end
  end

  # Reuse the existing generator as the outbox recovery trigger. Failed or
  # abandoned claims are retried; terminal provider outcomes stay put.
  def self.retry_enqueue_failures_for(family)
    WebPushDelivery.joins(web_push_subscription: :user)
      .where(users: { family_id: family.id })
      .where("web_push_deliveries.status = 'enqueue_failed' OR (web_push_deliveries.status = 'pending' AND (enqueued_at IS NULL OR enqueued_at < ?))", 15.minutes.ago)
      .find_each do |delivery|
      if delivery.eligible?
        delivery.enqueue!
      else
        delivery.with_lock { delivery.update!(status: :skipped) if delivery.status_pending? || delivery.status_enqueue_failed? }
      end
    end
  end

  def perform(web_push_delivery_id:)
    delivery = WebPushDelivery.find(web_push_delivery_id)
    # A row lock also serializes duplicate workers for the same material version.
    delivery.with_lock do
      return unless delivery.status_pending?
      unless delivery.eligible?
        delivery.update!(status: :skipped)
        return
      end
      result = WebPush::Client.new.deliver(subscription: delivery.web_push_subscription, payload: delivery.payload)
      if result == :gone
        delivery.web_push_subscription.destroy!
      else
        delivery.update!(status: result == :accepted ? :accepted : :rejected)
      end
    end
  end
end
