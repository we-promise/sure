class WebPushDelivery < ApplicationRecord
  belongs_to :web_push_subscription
  belongs_to :insight, optional: true

  enum :status, { pending: "pending", accepted: "accepted", skipped: "skipped",
    rejected: "rejected", failed: "failed", enqueue_failed: "enqueue_failed" }, prefix: true

  TEST_SEND_WINDOW = 15.minutes

  def self.for_insight(subscription, insight)
    create_or_find_by!(web_push_subscription: subscription, insight: insight,
      insight_version: insight.notification_version)
  end

  def enqueue!
    # Claim before contacting Redis. A process crash can leave this pending;
    # the next generation pass recovers claims older than the retry window.
    with_lock do
      return false unless status_pending? || status_enqueue_failed?
      update!(status: :pending, enqueued_at: Time.current)
    end
    job = DeliverWebPushNotificationJob.perform_later(web_push_delivery_id: id)
    return true if job
    update!(status: :enqueue_failed)
    false
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error
    update!(status: :enqueue_failed)
    false
  end

  def eligible?
    subscription = web_push_subscription
    return false unless WebPush::Client.configured? && subscription.eligible? && subscription.user.preview_features_enabled?
    if insight
      insight.notification_version == insight_version && subscription.eligible_for?(insight)
    else
      created_at > TEST_SEND_WINDOW.ago
    end
  end

  def payload
    I18n.with_locale(web_push_subscription.user.family.locale) do
      {
        title: Rails.configuration.x.product_name,
        body: I18n.t(insight ? "web_push.notification.body" : "web_push.notification.test_body"),
        tag: insight ? "insight-#{insight_id}" : "web-push-test-#{id}",
        data: { path: insight ? "/insights#insight_#{insight_id}" : "/insights" }
      }
    end
  end
end
