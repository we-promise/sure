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

host_scheme = begin
  URI.parse(Rails.configuration.x.posthog.host).scheme
rescue URI::InvalidURIError
  nil
end

# Both the server client below AND the browser snippet
# (app/views/shared/_posthog.html.erb, rendered from _head.html.erb) AND
# the CSP script-src/connect-src allowlist (content_security_policy.rb)
# send data to this host — posthog-ruby sends the API key in the request
# body and silently skips TLS when the scheme isn't https, and the browser
# integration would ship analytics/session data in cleartext the same way.
# A single `enabled` flag gates all three integration points so a bad
# POSTHOG_HOST disables PostHog everywhere instead of only wherever a
# reviewer happened to look first.
Rails.configuration.x.posthog.enabled = Rails.configuration.x.posthog.api_key.present? && host_scheme == "https"

if Rails.configuration.x.posthog.api_key.present? && !Rails.configuration.x.posthog.enabled
  Rails.logger.error("[PostHog] POSTHOG_HOST (#{Rails.configuration.x.posthog.host}) is not HTTPS — refusing to enable PostHog (server client, browser snippet, and CSP allowlist) to avoid sending the API key/analytics data in cleartext.")
end

if Rails.configuration.x.posthog.enabled
  # Initialize PostHog client
  $posthog = PostHog::Client.new({
    api_key: Rails.configuration.x.posthog.api_key,
    host: Rails.configuration.x.posthog.host,
    on_error: Proc.new { |status, msg| puts "PostHog error: #{status} - #{msg}" }
  })
end
