# frozen_string_literal: true

class DeliverInsightNotificationJob < ApplicationJob
  queue_as :scheduled

  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def self.enqueue_for(insight)
    return unless Apns::Client.configured?

    insight.family.users.includes(:push_subscriptions).find_each do |user|
      next unless user.preview_features_enabled?

      user.push_subscriptions.recent.find_each do |subscription|
        perform_later(insight_id: insight.id, push_subscription_id: subscription.id)
      end
    end
  end

  def perform(insight_id:, push_subscription_id:)
    insight = Insight.find(insight_id)
    subscription = PushSubscription.find(push_subscription_id)
    return unless subscription.user.family_id == insight.family_id

    response = I18n.with_locale(insight.family.locale) do
      Apns::Client.new(environment: subscription.environment).deliver(
        token: subscription.token,
        title: I18n.t("insights.notification.title"),
        body: I18n.t("insights.notification.body"),
        insight_id: insight.id
      )
    end
    return if response.ok?

    if invalid_token_response?(response)
      subscription.destroy!
      return
    end

    raise "APNs rejected notification with status #{response.status}: #{response.body.inspect}"
  rescue => e
    DebugLogEntry.capture(
      category: "insights",
      level: "error",
      message: "Failed to deliver insight notification: #{e.class}: #{e.message}",
      source: "DeliverInsightNotificationJob",
      family: insight&.family,
      metadata: { insight_id: insight_id, push_subscription_id: push_subscription_id }
    )
    raise
  end

  private
    def invalid_token_response?(response)
      response.status == "410" ||
        (response.status == "400" && response.body.is_a?(Hash) && response.body["reason"] == "BadDeviceToken")
    end
end
