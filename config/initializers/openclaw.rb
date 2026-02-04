Rails.application.configure do
  truthy = %w[1 true yes on]

  config.x.openclaw ||= ActiveSupport::OrderedOptions.new

  # Enable/disable OpenClaw provider
  enabled_env = ENV["OPENCLAW_ENABLED"].to_s.strip.downcase
  config.x.openclaw.enabled = truthy.include?(enabled_env)

  # WebSocket gateway URL (default: local)
  config.x.openclaw.gateway_url = ENV.fetch("OPENCLAW_GATEWAY_URL", "ws://127.0.0.1:18789")

  # Connection timeout in seconds
  config.x.openclaw.connection_timeout = ENV.fetch("OPENCLAW_CONNECTION_TIMEOUT", "10").to_i

  # Response timeout in seconds (longer for AI responses)
  config.x.openclaw.response_timeout = ENV.fetch("OPENCLAW_RESPONSE_TIMEOUT", "120").to_i
end
