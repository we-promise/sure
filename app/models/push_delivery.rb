# One delivery ledger for every push channel. A row is the durable record of
# "this subscription was a recipient of this insight version": created at the
# event, claimed before provider IO, completed with the provider outcome. The
# channel only decides how a payload is built and how a delivery call reports
# back; the idempotency, attempt budget and recovery live here. (Rule email
# deliveries keep their own NotificationDelivery ledger; their dedup domain is
# a rule matched against a transaction, not an insight version.)
class PushDelivery < ApplicationRecord
  belongs_to :subscription, polymorphic: true
  belongs_to :insight, optional: true

  enum :status, { pending: "pending", accepted: "accepted", skipped: "skipped",
    rejected: "rejected", failed: "failed", enqueue_failed: "enqueue_failed" }, prefix: true

  TEST_SEND_WINDOW = 15.minutes
  CLAIM_TIMEOUT = 15.minutes
  MAX_PROVIDER_ATTEMPTS = 5

  CHANNEL_JOBS = {
    "PushSubscription" => "DeliverInsightNotificationJob",
    "WebPushSubscription" => "DeliverWebPushNotificationJob"
  }.freeze

  scope :apns, -> { where(subscription_type: "PushSubscription") }
  scope :web_push, -> { where(subscription_type: "WebPushSubscription") }

  # Called inside the insight version's transaction. Recipient eligibility is
  # captured at the event, so later registration or opt-in cannot add a backlog.
  def self.record_for_insight!(insight)
    return unless insight.active?

    if Apns::Client.available?
      PushSubscription.joins(:user).recent
        .where(users: { family_id: insight.family_id, active: true })
        .includes(:user).find_each do |subscription|
        for_subscription(subscription, insight) if subscription.eligible_for?(insight)
      end
    end

    if WebPush::Client.configured?
      WebPushSubscription.joins(:user)
        .where(users: { family_id: insight.family_id, active: true })
        .includes(:user, :session).find_each do |subscription|
        for_subscription(subscription, insight) if subscription.eligible_for?(insight)
      end
    end
  end

  def self.for_subscription(subscription, insight)
    transaction do
      # The device can disappear after event-time eligibility was read. Lock
      # the parent before inserting its ledger row so deletion cannot race it.
      locked = subscription.class.lock.find_by(id: subscription.id)
      next unless locked
      create_or_find_by!(subscription: locked, insight: insight,
        insight_version: insight.notification_version)
    end
  end

  # Both channels enqueue from the same event: unclaimed pending rows and rows
  # whose enqueue failed get one claim each.
  def self.enqueue_insight_deliveries(insight)
    deliveries = where(insight: insight, insight_version: insight.notification_version)
    deliveries.where(status: :enqueue_failed)
      .or(deliveries.where(status: :pending, enqueued_at: nil))
      .find_each do |delivery|
      delivery.enqueue! if delivery.eligible?
    end
  end

  # The generator is the outbox recovery trigger. Failed or abandoned claims
  # are retried; terminal provider outcomes stay put.
  def self.retry_enqueue_failures_for(family)
    apns.joins("INNER JOIN push_subscriptions ON push_subscriptions.id = push_deliveries.subscription_id")
      .joins("INNER JOIN users ON users.id = push_subscriptions.user_id")
      .where(users: { family_id: family.id }).recoverable.find_each(&:recover!)

    web_push.joins("INNER JOIN web_push_subscriptions ON web_push_subscriptions.id = push_deliveries.subscription_id")
      .joins("INNER JOIN users ON users.id = web_push_subscriptions.user_id")
      .where(users: { family_id: family.id }).recoverable.find_each(&:recover!)
  end

  scope :recoverable, -> {
    where(status: :enqueue_failed).or(
      where(status: :pending).where("enqueued_at IS NULL OR enqueued_at < ?", CLAIM_TIMEOUT.ago)
    )
  }

  def recover!
    if eligible?
      enqueue!(recover: true)
    else
      with_lock { update!(status: :skipped) if status_pending? || status_enqueue_failed? }
    end
  end

  def enqueue!(recover: false)
    return false unless subscription.channel_ready?

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

    job = deliver_job.constantize.perform_later(push_delivery_id: id)
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
    return unless subscription.channel_ready?

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

  def complete_attempt!(attempt, result:, subscription_updated_at: nil)
    if result == :gone
      # Registration takes parent then child locks. Cleanup uses that same
      # order, and never holds either lock while contacting the provider.
      self.class.transaction do
        subscription = WebPushSubscription.lock.find_by(id: subscription_id)
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
    if insight
      insight.notification_version == insight_version && subscription.eligible_for?(insight)
    else
      # Test sends exist only on the web push channel and expire quickly.
      subscription.is_a?(WebPushSubscription) && subscription.eligible? &&
        subscription.user.preview_features_enabled? && created_at > TEST_SEND_WINDOW.ago
    end
  end

  def payload
    subscription.notification_payload(delivery: self)
  end

  def deliver_job
    CHANNEL_JOBS.fetch(subscription_type)
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
