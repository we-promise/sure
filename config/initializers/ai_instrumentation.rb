# Usage rows, the debug log and tracing for AI calls (app/models/ai/instrumentation.rb).
#
# The subscribers are reloadable code, so they're subscribed again on every reload and the
# previous ones removed; the OpenTelemetry tracer provider (metadata mode) is set once.
Rails.application.config.to_prepare do
  Array(Rails.application.config.x.ai_subscriptions).each { ActiveSupport::Notifications.unsubscribe(_1) }
  Rails.application.config.x.ai_subscriptions = Ai::Instrumentation.subscribe!
end

Rails.application.config.after_initialize do
  Ai::Instrumentation.start_tracing!
end
