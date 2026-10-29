class WebPushDelivery < ApplicationRecord
  belongs_to :web_push_subscription
  belongs_to :insight, optional: true

  enum :status, { pending: "pending", accepted: "accepted", skipped: "skipped",
    rejected: "rejected", failed: "failed", enqueue_failed: "enqueue_failed" }, prefix: true

  TEST_SEND_WINDOW = 15.minutes
  CLAIM_TIMEOUT = 15.minutes

  # Called inside the insight version's transaction. Recipient eligibility is
  # captured at the event, so later registration or opt-in cannot add a backlog.
  def self.record_for_insight!(insight)
    return unless WebPush::Client.configured? && insight.active?

    WebPushSubscription.joins(:user).where(users: { family_id: insight.family_id, active: true })
      .includes(:user, :session).find_each do |subscription|
      for_insight(subscription, insight) if subscription.eligible_for?(insight)
    end
  end

  def self.for_insight(subscription, insight)
    create_or_find_by!(web_push_subscription: subscription, insight: insight,
      insight_version: insight.notification_version)
  end

  def enqueue!(recover: false)
    # Claim before contacting Redis. A process crash can leave this pending;
    # the next generation pass recovers claims older than the retry window.
    with_lock do
      claim_available = enqueued_at.nil? || (recover && enqueued_at < CLAIM_TIMEOUT.ago)
      return false unless status_enqueue_failed? || (status_pending? && claim_available)
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
