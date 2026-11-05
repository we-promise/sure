class WebPushDelivery < ApplicationRecord
  belongs_to :web_push_subscription
  belongs_to :insight, optional: true

  enum :status, { pending: "pending", accepted: "accepted", skipped: "skipped",
    rejected: "rejected", failed: "failed", enqueue_failed: "enqueue_failed" }, prefix: true

  TEST_SEND_WINDOW = 15.minutes
  CLAIM_TIMEOUT = 15.minutes
  MAX_PROVIDER_ATTEMPTS = 5

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
    transaction do
      # The device can disappear after event-time eligibility was read. Lock
      # the parent before inserting its ledger row so deletion cannot race it.
      current_subscription = WebPushSubscription.lock.find_by(id: subscription.id)
      next unless current_subscription
      create_or_find_by!(web_push_subscription: current_subscription, insight: insight,
        insight_version: insight.notification_version)
    end
  end

  def enqueue!(recover: false)
    return false unless WebPush::Client.configured?

    claimed_at = Time.current
    claimed = with_lock do
      claim_available = enqueued_at.nil? || (recover && enqueued_at < CLAIM_TIMEOUT.ago)
      next false unless status_enqueue_failed? || (status_pending? && claim_available)
      next false if attempted_at && attempted_at > CLAIM_TIMEOUT.ago
      if provider_attempts >= MAX_PROVIDER_ATTEMPTS
        update!(status: :failed)
        next false
      end
      update!(status: :pending, enqueued_at: claimed_at)
      true
    end
    return false unless claimed

    job = DeliverWebPushNotificationJob.perform_later(web_push_delivery_id: id)
    return true if job
    mark_enqueue_failed!(claimed_at)
    false
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error
    mark_enqueue_failed!(claimed_at)
    false
  end

  # The reservation commits before provider IO. A lost worker therefore spends
  # an attempt, and a recovered ActiveJob cannot start a fresh provider budget.
  def claim_attempt!
    return unless WebPush::Client.configured?

    with_lock do
      next unless status_pending?
      next if attempted_at && attempted_at > CLAIM_TIMEOUT.ago
      unless eligible?
        update!(status: :skipped)
        next
      end
      if provider_attempts >= MAX_PROVIDER_ATTEMPTS
        update!(status: :failed)
        next
      end
      update!(provider_attempts: provider_attempts + 1, attempted_at: Time.current)
      provider_attempts
    end
  end

  def retry_attempt!(attempt)
    with_lock do
      next false unless current_attempt?(attempt)
      update!(attempted_at: nil, status: provider_attempts >= MAX_PROVIDER_ATTEMPTS ? :failed : :pending)
      status_pending?
    end
  end

  def complete_attempt!(attempt, result:, subscription_updated_at:)
    if result == :gone
      # Registration takes parent then child locks. Cleanup uses that same
      # order, and never holds either lock while contacting the provider.
      self.class.transaction do
        subscription = WebPushSubscription.lock.find_by(id: web_push_subscription_id)
        next unless subscription
        with_lock do
          next unless current_attempt?(attempt)
          if subscription.updated_at == subscription_updated_at
            subscription.destroy!
          else
            update!(status: :rejected, attempted_at: nil)
          end
        end
      end
    else
      with_lock do
        next unless current_attempt?(attempt)
        update!(status: result == :accepted ? :accepted : :rejected, attempted_at: nil)
      end
    end
  end

  def eligible?
    subscription = web_push_subscription
    return false unless subscription.eligible? && subscription.user.preview_features_enabled?
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

  private
    def current_attempt?(attempt)
      status_pending? && provider_attempts == attempt
    end

    def mark_enqueue_failed!(claimed_at)
      self.class.where(id: id, status: :pending, enqueued_at: claimed_at, attempted_at: nil)
        .update_all(status: :enqueue_failed, updated_at: Time.current)
    end
end
