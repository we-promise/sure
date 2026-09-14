module SankeyFeedbackHelper
  def sankey_feedback_config
    config = Rails.configuration.x.posthog
    return {} unless self_hosted? && Rails.env.production? && config.feedback_api_key.present? && config.sankey_survey_id.present?

    # Operators explicitly configure the shared feedback destination. Never send
    # their normal analytics to it or fall back to their private PostHog project.
    { api_key: config.feedback_api_key, host: config.feedback_host }
  end
end
