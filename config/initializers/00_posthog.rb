require "posthog"

Rails.configuration.x.posthog = ActiveSupport::OrderedOptions.new
Rails.configuration.x.posthog.api_key = ENV["POSTHOG_KEY"].presence
Rails.configuration.x.posthog.host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")

if (api_key = Rails.configuration.x.posthog.api_key).present?
  # Initialize PostHog client
  $posthog = PostHog::Client.new({
    api_key: api_key,
    host: Rails.configuration.x.posthog.host,
    on_error: Proc.new { |status, msg| puts "PostHog error: #{status} - #{msg}" }
  })
end
