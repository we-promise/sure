require "opentelemetry/sdk"
require "opentelemetry-exporter-otlp"

# The `metadata` tracing mode (section 10): RubyLLM's own OpenTelemetry spans (model, settings,
# finish reason, tokens, latency, error class) go to any OTLP backend at OTLP_ENDPOINT, with no
# prompt, tool result or answer. It loses the route, the prompt key, Sure's error class and
# errors raised before RubyLLM is called.
#
# RubyLLM 2.1.1 has no code to put content on spans. 2.2 adds `enable(content: true)` (#1333),
# off by default; `content: false` is passed explicitly whenever the gem accepts it, and
# test/models/ai/instrumentation/metadata_tracing_test.rb fails if any span carries content.
module Ai::Instrumentation::MetadataTracing
  # RubyLLM can't set a session, and Langfuse doesn't copy a parent span's session to its
  # children, so every span gets the job's correlation id when it starts.
  class CorrelationProcessor < OpenTelemetry::SDK::Trace::SpanProcessor
    def on_start(span, _parent_context)
      id = Ai::CallContext.current&.correlation_id || Ai::CallContext.correlation_id
      span.set_attribute("session.id", id.to_s) if id.present?
    end
  end

  module_function

  # The app owns the tracer provider and exporter, as RubyLLM's OpenTelemetry docs ask.
  def enable(endpoint: ENV["OTLP_ENDPOINT"], headers: ENV["OTLP_HEADERS"], processor: nil)
    processor ||= OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint:, headers: parse_headers(headers))
    )
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(CorrelationProcessor.new)
    provider.add_span_processor(processor)
    OpenTelemetry.tracer_provider = provider

    if RubyLLM::OpenTelemetry.method(:enable).parameters.any? { |_, name| name == :content }
      RubyLLM::OpenTelemetry.enable(content: false)
    else
      RubyLLM::OpenTelemetry.enable
    end
    provider
  end

  # OTLP_HEADERS uses the OpenTelemetry form: `key=value,key=value`, values URL-encoded.
  def parse_headers(value)
    value.to_s.split(",").filter_map do |pair|
      key, header = pair.split("=", 2).map { _1.to_s.strip }
      [ key, CGI.unescape(header.to_s) ] if key.present?
    end.to_h
  end
end
