# frozen_string_literal: true

# Short-lived operator diagnostics, like WorkerAiHealth. Production web and
# Sidekiq must use the same Redis cache. This is not an insight delivery ledger.
class PushNotificationTest
  RETENTION = 24.hours
  SEND_WINDOW = 15.minutes
  COOLDOWN = 30.seconds
  TERMINAL_STATUSES = %w[accepted skipped rejected unregistered failed enqueue_failed].freeze

  attr_reader :user

  def initialize(user, cache: Rails.cache)
    @user = user
    @cache = cache
  end

  def disabled_reason
    return :hosted_only unless Apns::Client.hosted?
    return :ineligible unless user.active? && user.super_admin?
    return :no_devices unless user.push_subscriptions.recent.exists?
    return :disabled if ENV["APNS_ENABLED"] == "false"
    return :not_configured unless Apns::Client.configured?
    request = latest
    :cooldown if request && request[:created_at] > COOLDOWN.ago
  end

  def latest
    @cache.read(latest_key)
  end

  def results(request)
    request[:subscriptions].map do |subscription|
      result = @cache.read(result_key(request[:id], subscription[:id]))
      result = nil if result && !TERMINAL_STATUSES.include?(result[:status]) && request[:created_at] < SEND_WINDOW.ago
      status = request[:created_at] < SEND_WINDOW.ago ? "expired" : "queued"
      subscription.merge(result || { status: status, checked_at: nil })
    end
  end

  def request!
    # Serialize double-clicks across web processes for this account.
    user.with_lock do
      reason = disabled_reason
      return reason if reason

      subscriptions = user.push_subscriptions.recent.order(:id).map { |s| { id: s.id, environment: s.environment } }
      return :no_devices if subscriptions.empty?

      request = { id: SecureRandom.uuid, created_at: Time.current, subscriptions: subscriptions }
      return :storage_unavailable unless @cache.write(request_key(request[:id]), request, expires_in: RETENTION)
      return :storage_unavailable unless @cache.write(latest_key, request, expires_in: RETENTION)

      queued = 0
      subscriptions.each do |subscription|
        begin
          job = DeliverTestPushNotificationJob.perform_later(
            user_id: user.id, request_id: request[:id], push_subscription_id: subscription[:id]
          )
          if job
            queued += 1
          else
            record(request[:id], subscription[:id], :enqueue_failed)
          end
        rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error
          record(request[:id], subscription[:id], :enqueue_failed)
        end
      end
      queued.positive? ? :queued : :enqueue_failed
    end
  end

  def deliver(request_id:, push_subscription_id:)
    request = @cache.read(request_key(request_id))
    return unless request && request[:subscriptions].any? { |s| s[:id] == push_subscription_id }

    # Each device has its own result key: one worker cannot overwrite another
    # device's outcome. Terminal results suppress ordinary job replays.
    previous = @cache.read(result_key(request_id, push_subscription_id))
    return if previous && TERMINAL_STATUSES.include?(previous[:status])

    subscription = user.push_subscriptions.find_by(id: push_subscription_id)
    unless Apns::Client.available? && user.active? && user.super_admin? &&
        subscription&.eligible? && request[:created_at] > SEND_WINDOW.ago
      return record(request_id, push_subscription_id, :skipped)
    end

    result = PushSubscription::Delivery.new(subscription).call do |client|
      I18n.with_locale(user.locale.presence || user.family.locale) do
        client.deliver_test(
          token: subscription.token,
          title: I18n.t("admin.system_health.push_notification.title"),
          body: I18n.t("admin.system_health.push_notification.body"),
          request_id: request_id
        )
      end
    end
    record(request_id, push_subscription_id, result)
  rescue Apns::Client::TransientError
    record(request_id, push_subscription_id, :retrying)
    raise
  end

  def record(request_id, subscription_id, status)
    @cache.write(result_key(request_id, subscription_id),
      { status: status.to_s, checked_at: Time.current }, expires_in: RETENTION)
  end

  private
    def latest_key
      "push_notification_test/v1/#{user.id}/latest"
    end

    def request_key(request_id)
      "push_notification_test/v1/#{user.id}/#{request_id}"
    end

    def result_key(request_id, subscription_id)
      "#{request_key(request_id)}/#{subscription_id}"
    end
end
