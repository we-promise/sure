require "opentelemetry/sdk"
require "opentelemetry-exporter-otlp"
require "base64"
require "json"

class LangfuseTracing
  def initialize(public_key:, secret_key:, host:, processor: nil, auto_flush: true)
    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    @provider.add_span_processor(processor || OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{host.chomp('/')}/api/public/otel/v1/traces",
        headers: {
          "Authorization" => "Basic #{Base64.strict_encode64("#{public_key}:#{secret_key}")}",
          "x-langfuse-ingestion-version" => "4"
        }
      ), start_thread_on_boot: auto_flush
    ))
    @tracer = @provider.tracer("sure.langfuse")
  end

  def trace(name:, input:, session_id: nil, user_id: nil, environment: Rails.env, metadata: {}, attributes: {}, start_time: nil)
    context = {
      "langfuse.trace.name" => name,
      "langfuse.session.id" => session_id,
      "langfuse.user.id" => user_id,
      "langfuse.environment" => environment.to_s
    }.compact.merge(attributes)
    metadata.each { |key, value| context["langfuse.trace.metadata.#{key}"] = value.is_a?(String) ? value : JSON.generate(value) }
    Observation.new(@tracer, name: name, input: input, attributes: context, start_time: start_time)
  end

  def flush
    @provider.force_flush(timeout: 30)
  end

  def shutdown
    @provider.shutdown(timeout: 30)
  end

  class Observation
    attr_reader :span_id, :id, :start_time

    def initialize(tracer, name:, input:, attributes:, parent: nil, type: "span", model: nil, start_time: nil)
      @tracer = tracer
      @attributes = attributes
      @start_time = start_time || Time.now
      @span = tracer.start_span(name, with_parent: parent || OpenTelemetry::Context.empty, attributes: attributes.merge(
        "langfuse.observation.type" => type,
        "langfuse.observation.input" => JSON.generate(input),
        "langfuse.observation.model.name" => model,
        "langfuse.internal.as_root" => parent.nil?
      ).compact, start_timestamp: @start_time)
      @id = @span.context.hex_trace_id
      @span_id = @span.context.hex_span_id
    end

    def span(name:, input:)
      child(name: name, input: input)
    end

    def generation(name:, input:, model:, start_time: nil)
      child(name: name, input: input, type: "generation", model: model, start_time: start_time)
    end

    def end(output: nil, usage: nil, level: nil)
      return unless @span.recording?

      @span.set_attribute("langfuse.observation.output", JSON.generate(output))
      @span.set_attribute("langfuse.observation.level", level) if level
      @span.status = OpenTelemetry::Trace::Status.error if level == "ERROR"
      @span.set_attribute("langfuse.observation.usage_details", JSON.generate(usage_details(usage))) if usage
      @span.finish
    rescue => error
      Rails.logger.warn("Langfuse observation failed: #{error.class}")
    ensure
      @span.finish if @span.recording?
    end

    def set_attributes(attributes)
      @span.add_attributes(attributes)
    end

    private

      def child(name:, input:, type: "span", model: nil, start_time: nil)
        self.class.new(@tracer, name: name, input: input, model: model, type: type,
          attributes: @attributes, parent: OpenTelemetry::Trace.context_with_span(@span), start_time: start_time)
      rescue => error
        Rails.logger.warn("Langfuse observation creation failed: #{error.class}")
        nil
      end

      def usage_details(usage)
        usage = usage.to_h.transform_keys(&:to_s)
        cached = usage.dig("prompt_tokens_details", "cached_tokens") || usage.dig("input_tokens_details", "cached_tokens")
        input = usage["input_tokens"] || usage["prompt_tokens"]
        details = {
          input: cached && input ? input - cached : input,
          output: usage["output_tokens"] || usage["completion_tokens"],
          input_cached_tokens: cached,
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_creation_input_tokens: usage["cache_creation_input_tokens"]
        }.compact
        total = details.key?(:input) && details.key?(:output) ? details.values.sum : usage["total_tokens"]
        details.merge(total: total).compact
      end
  end
end
