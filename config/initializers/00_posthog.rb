require "posthog"

Rails.configuration.x.posthog = ActiveSupport::OrderedOptions.new
Rails.configuration.x.posthog.api_key = ENV["POSTHOG_KEY"].presence
# .presence (not .fetch) so an explicitly-blank POSTHOG_HOST="" still falls
# back to the default instead of reaching PostHog::Client as an empty string.
Rails.configuration.x.posthog.host = ENV["POSTHOG_HOST"].presence || "https://us.i.posthog.com"

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
