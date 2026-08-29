require "posthog"

Rails.configuration.x.posthog = ActiveSupport::OrderedOptions.new
Rails.configuration.x.posthog.api_key = ENV["POSTHOG_KEY"].presence
# .presence (not .fetch) so an explicitly-blank POSTHOG_HOST="" still falls
# back to the default instead of reaching PostHog::Client as an empty string.
Rails.configuration.x.posthog.host = ENV["POSTHOG_HOST"].presence || "https://us.i.posthog.com"

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
