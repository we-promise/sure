module FeedbackHelper
  def posthog_enabled?
    Rails.env.production? || (Rails.env.development? && Rails.configuration.x.posthog.development_enabled)
  end

  def sankey_tracking_config
    config = Rails.configuration.x.posthog
    return {} unless self_hosted? && posthog_enabled? && config.feedback_enabled

    config.self_hosted_feedback_project
  end
end
