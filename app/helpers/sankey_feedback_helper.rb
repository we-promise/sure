module SankeyFeedbackHelper
  def sankey_feedback_config
    config = Rails.configuration.x.posthog
    return { survey_id: config.sankey_survey_id } unless self_hosted?
    return {} unless Rails.env.production? && config.feedback_enabled

    # The preview uses the bundled public destination, independently of any
    # analytics project or survey configured by the self-hosting operator.
    config.self_hosted_feedback
  end
end
