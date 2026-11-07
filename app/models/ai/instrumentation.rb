# AI instrumentation as subscribers to one set of events (section 10). Usage rows and the debug
# log run in every mode; tracing has two modes, never at once, or Langfuse would get each
# generation twice:
#
#   content   Sure's `.ai` events through LangfuseSubscriber: prompts, outputs, usage, route,
#             Sure's error class and session. The default, when Langfuse keys are set.
#   metadata  RubyLLM's OpenTelemetry spans to OTLP_ENDPOINT: model, settings, tokens, latency,
#             no content. For operators who want cost and latency without sending financial
#             data to a tracing backend.
#   off       Neither.
#
# The mode follows from the variables an operator already sets, so no AI variable is added
# (section 4.7): Langfuse keys mean content, OTLP_ENDPOINT alone means metadata.
module Ai::Instrumentation
  MODES = %i[content metadata off].freeze

  module_function

  def mode(env: ENV)
    langfuse = env["LANGFUSE_PUBLIC_KEY"].present? && env["LANGFUSE_SECRET_KEY"].present?
    return :content if langfuse
    return :metadata if env["OTLP_ENDPOINT"].present?

    :off
  end

  # The subscribers for this mode, returned so the caller can unsubscribe them when code
  # reloads (config/initializers/ai_instrumentation.rb).
  def subscribe!(env: ENV)
    usage = UsageSubscriber.new
    subscriptions = [
      ActiveSupport::Notifications.subscribe("usage.ruby_llm", usage),
      ActiveSupport::Notifications.subscribe(/\.ai\z/, usage),
      ActiveSupport::Notifications.subscribe(/\.ai\z/, DebugLogSubscriber.new)
    ]
    subscriptions << ActiveSupport::Notifications.subscribe(/\.ai\z/, LangfuseSubscriber.new) if mode(env:) == :content
    subscriptions
  end

  # Once per process: metadata mode sets the global OpenTelemetry tracer provider.
  def start_tracing!(env: ENV)
    case mode(env:)
    when :content then warn_both_tracing_modes if env["OTLP_ENDPOINT"].present?
    when :metadata
      provider = MetadataTracing.enable(endpoint: env["OTLP_ENDPOINT"], headers: env["OTLP_HEADERS"])
      # The batch processor exports on a timer; without a shutdown a process loses its last batch
      # at exit, which for a rake task or `rails runner` is every span (seen live against Langfuse).
      at_exit { provider.shutdown }
    end
  end

  def warn_both_tracing_modes
    Rails.logger.warn("[AI] Langfuse keys and OTLP_ENDPOINT are both set: tracing in content mode (Langfuse). " \
                      "Unset the Langfuse keys to send metadata-only spans to OTLP_ENDPOINT instead.")
  end
  private_class_method :warn_both_tracing_modes
end
