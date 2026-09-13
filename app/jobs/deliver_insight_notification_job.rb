# frozen_string_literal: true

class DeliverInsightNotificationJob < ApplicationJob
  queue_as :scheduled

  retry_on Apns::Client::TransientError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def self.enqueue_for(insight)
    return unless Apns::Client.available? && insight.priority_high? && insight.active?

    insight.family.users.includes(:push_subscriptions).find_each do |user|
      next unless user.active? && user.preview_features_enabled?

      user.push_subscriptions.recent.find_each do |subscription|
        perform_later(insight_id: insight.id, push_subscription_id: subscription.id)
      end
    end
  end

  def perform(insight_id:, push_subscription_id:)
    return unless Apns::Client.available?

    insight = Insight.find(insight_id)
    subscription = PushSubscription.find(push_subscription_id)
    return unless subscription.user.family_id == insight.family_id
    return unless subscription.eligible? && subscription.user.preview_features_enabled?
    return unless insight.priority_high? && insight.active?

    PushSubscription::Delivery.new(subscription).call do |client|
      I18n.with_locale(insight.family.locale) do
        client.deliver(
          token: subscription.token,
          title: I18n.t("insights.notification.title"),
          body: I18n.t("insights.notification.body"),
          insight_id: insight.id
        )
      end
    end
  end
end
