require "posthog"

Rails.configuration.x.posthog = ActiveSupport::OrderedOptions.new
Rails.configuration.x.posthog.api_key = ENV["POSTHOG_KEY"].presence
Rails.configuration.x.posthog.host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")
Rails.configuration.x.posthog.feedback_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("POSTHOG_FEEDBACK_ENABLED", "true"))
# Public client configuration for the shared self-hosted feedback project.
# This write-only project token is safe to distribute; it is not an admin key.
# https://posthog.com/docs/api
Rails.configuration.x.posthog.self_hosted_feedback = {
  api_key: "phc_D4stYbjnouz4J3H434HjYNQ655XG4vqL99HJH7cA4zMk",
  host: "https://us.i.posthog.com",
  survey_id: "01a0a162-73a2-0000-9402-ffab5bc45b4a"
}.freeze
Rails.configuration.x.posthog.sankey_survey_id = ENV["POSTHOG_SANKEY_SURVEY_ID"].presence

if (api_key = Rails.configuration.x.posthog.api_key).present?
  # Initialize PostHog client
  $posthog = PostHog::Client.new({
    api_key: api_key,
    host: Rails.configuration.x.posthog.host,
    on_error: Proc.new { |status, msg| puts "PostHog error: #{status} - #{msg}" }
  })
end
