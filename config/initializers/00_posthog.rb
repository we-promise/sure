require "posthog"

Rails.configuration.x.posthog = ActiveSupport::OrderedOptions.new
# Explicit opt-in for local browser testing; production behavior is unchanged.
Rails.configuration.x.posthog.development_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("POSTHOG_DEVELOPMENT_ENABLED", "false"))
Rails.configuration.x.posthog.api_key = ENV["POSTHOG_KEY"].presence
# .presence (not .fetch) so an explicitly-blank POSTHOG_HOST="" still falls
# back to the default instead of reaching PostHog::Client as an empty string.
Rails.configuration.x.posthog.host = ENV["POSTHOG_HOST"].presence || "https://us.i.posthog.com"
Rails.configuration.x.posthog.feedback_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("POSTHOG_FEEDBACK_ENABLED", "true"))
# Public client configuration for the shared self-hosted feedback project.
# This write-only project token is safe to distribute; it is not an admin key.
# https://posthog.com/docs/api
Rails.configuration.x.posthog.self_hosted_feedback_project = {
  api_key: "phc_D4stYbjnouz4J3H434HjYNQ655XG4vqL99HJH7cA4zMk",
  host: "https://us.i.posthog.com"
}.freeze
# Register each feature's survey separately from the shared project destination.
# Managed app/demo deployments provide the survey belonging to their own project.
Rails.configuration.x.posthog.feedback_surveys = {
  sankey: {
    managed: ENV["POSTHOG_SANKEY_SURVEY_ID"].presence,
    self_hosted: "01a0a162-73a2-0000-9402-ffab5bc45b4a"
  }.freeze
}.freeze

if (api_key = Rails.configuration.x.posthog.api_key).present?
  host = Rails.configuration.x.posthog.host

  # posthog-ruby sends the API key in the request body and silently skips
  # TLS when the host's scheme isn't https, so a misconfigured (or
  # accidentally http://) POSTHOG_HOST would leak the key in cleartext.
  # Refuse to start the client rather than crash boot over an env var only
  # a self-hosted operator controls.
  host_scheme = begin
    URI.parse(host).scheme
  rescue URI::InvalidURIError
    nil
  end

  if host_scheme == "https"
    # Initialize PostHog client
    $posthog = PostHog::Client.new({
      api_key: api_key,
      host: host,
      on_error: Proc.new { |status, msg| puts "PostHog error: #{status} - #{msg}" }
    })
  else
    Rails.logger.error("[PostHog] POSTHOG_HOST (#{host}) is not HTTPS — refusing to initialize the PostHog client to avoid sending the API key in cleartext.")
  end
end
