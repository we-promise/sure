# The `content` tracing mode: each `.ai` event becomes a Langfuse trace with one
# generation holding the request, the output, usage and the error. Health probes aren't traced:
# they carry no family data and run every time an admin opens the health page.
class Ai::Instrumentation::LangfuseSubscriber
  SKIPPED = %w[probe.ai].freeze

  def initialize(client: Rails.configuration.x.langfuse, environment: Rails.env)
    @client = client
    @environment = environment
  end

  def call(event)
    return if @client.nil? || SKIPPED.include?(event.name)

    payload = event.payload
    scrub = payload[:scrub] || Ai::Instrumentation::Redactor.method(:scrub)
    input = plain(payload[:request], scrub)
    output = payload[:error] ? { error: payload[:error], message: payload[:error_message] } : plain(payload[:output], scrub)
    level = payload[:error] ? "ERROR" : nil

    trace = @client.trace(name: "#{payload[:feature] || "ai"}.#{event.name.delete_suffix(".ai")}", input:,
                          environment: @environment, start_time: event_start(event),
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

    def event_start(event) = Time.current - (event.duration.to_f / 1000)

    # Value objects become plain hashes, all the way down; the endpoint's key and header values,
    # and anything shaped like a key, are scrubbed from strings.
    def plain(value, scrub)
      case value
      when Data then plain(value.to_h, scrub)
      when Hash then value.transform_values { plain(_1, scrub) }
      when Array then value.map { plain(_1, scrub) }
      when String then scrub.call(value)
      else value
      end
    end
end
