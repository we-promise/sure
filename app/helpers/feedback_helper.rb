module FeedbackHelper
  def posthog_enabled?
    Rails.env.production? || (Rails.env.development? && Rails.configuration.x.posthog.development_enabled)
  end

  def feedback_config(feature)
    config = Rails.configuration.x.posthog
    destination = self_hosted? ? :self_hosted : :managed
    return {} if destination == :self_hosted && !(posthog_enabled? && config.feedback_enabled)

    survey_id = config.feedback_surveys.dig(feature, destination).presence
    return {} unless survey_id

    # Managed feedback uses the environment's existing SDK. Self-hosted feedback
    # uses the shared public project, independently of operator-owned analytics.
    project = destination == :self_hosted ? config.self_hosted_feedback_project : {}
    project.merge(survey_id: survey_id)
  end
end
