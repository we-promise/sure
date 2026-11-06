# The `content` tracing mode (section 10): each `.ai` event becomes a Langfuse trace with one
# generation holding the request, the output, usage and the error. The correlation id is the
# Langfuse session, so a job's calls group together. Health probes aren't traced: they carry
# no family data and run every time an admin opens the health page.
class Ai::Instrumentation::LangfuseSubscriber
  SKIPPED = %w[probe.ai].freeze

  def initialize(client: Rails.configuration.x.langfuse, environment: Rails.env)
    @client = client
    @environment = environment
  end

  def call(event)
    return if @client.nil? || SKIPPED.include?(event.name)

    payload = event.payload
    input = plain(payload[:request])
    output = payload[:error] ? { error: payload[:error], message: payload[:error_message] } : plain(payload[:output])
    level = payload[:error] ? "ERROR" : nil

    trace = @client.trace(name: "#{payload[:feature] || "ai"}.#{event.name.delete_suffix(".ai")}", input:,
                          session_id: payload[:correlation_id], environment: @environment, start_time: event_start(event),
                          metadata: { route: payload[:route], call_id: payload[:call_id], error: payload[:error] }.compact)
    generation = trace&.generation(name: event.name, input:, model: payload.dig(:route, :model), start_time: event_start(event))
    generation&.end(output:, usage: usage(payload[:usage]), level:)
    trace&.end(output:, level:)
  rescue StandardError => error
    Rails.logger.warn("[Ai::Instrumentation::LangfuseSubscriber] #{error.class}")
  end

  private
    # Langfuse wants the whole prompt, cached tokens included, as input.
    def usage(tokens)
      return unless tokens.is_a?(Ai::Tokens) && tokens.known?

      { input_tokens: tokens.prompt_tokens.to_i, output_tokens: tokens.output_tokens.to_i,
        prompt_tokens_details: { cached_tokens: tokens.cache_read_tokens.to_i } }
    end

    def event_start(event)
      Time.current - (event.duration.to_f / 1000)
    rescue StandardError
      Time.current
    end

    # Value objects become plain hashes, all the way down; keys are scrubbed from strings.
    def plain(value)
      case value
      when Data then plain(value.to_h)
      when Hash then value.transform_values { plain(_1) }
      when Array then value.map { plain(_1) }
      when String then Ai::Instrumentation::Redactor.scrub(value)
      else value
      end
    end
end
