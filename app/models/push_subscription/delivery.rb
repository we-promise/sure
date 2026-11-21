# frozen_string_literal: true

# Shared response handling for financial alerts and explicit admin diagnostics.
class PushSubscription::Delivery
  def initialize(subscription)
    @subscription = subscription
  end

  def call
    return :skipped unless Apns::Client.available? && @subscription.eligible?

    response = yield Apns::Client.new(environment: @subscription.environment)
    return :accepted if response.ok?

    status = response.status.to_i
    if status == 429 || (500..599).cover?(status)
      raise Apns::Client::TransientError, "APNs temporarily rejected the request (#{status})"
    end

    record_failure(status)
    # :gone leaves removing the subscription to the caller. BadDeviceToken can
    # mean the environment is wrong, so other errors preserve the record for
    # diagnosis and renewal.
    status == 410 && @subscription.unregistered_by?(response) ? :gone : :rejected
  rescue Apns::Client::UnavailableError
    :skipped
  rescue Apns::Client::ConfigurationError
    record_failure(:configuration)
    :failed
  rescue Apns::Client::TransientError
    record_failure(:transient)
    raise
  end

  private
    def record_failure(code)
      DebugLogEntry.capture(
        category: "push_notifications", level: "error",
        message: "Push delivery failed (#{code})", source: self.class.name,
        user: @subscription.user, family: @subscription.user.family,
        metadata: { push_subscription_id: @subscription.id, environment: @subscription.environment, failure_code: code }
      )
    end
end
