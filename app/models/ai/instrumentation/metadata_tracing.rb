require "opentelemetry/sdk"
require "opentelemetry-exporter-otlp"

# The `metadata` tracing mode: RubyLLM's own OpenTelemetry spans (model, settings,
# finish reason, tokens, latency, error class) go to any OTLP backend at OTLP_ENDPOINT, with no
# prompt, tool result or answer. It loses the route, the prompt key, Sure's error class and
# errors raised before RubyLLM is called.
#
# RubyLLM 2.1.1 has no code to put content on spans. 2.2 adds `enable(content: true)` (RubyLLM #1333),
# off by default; `content: false` is passed explicitly whenever the gem accepts it, and
# test/models/ai/instrumentation/metadata_tracing_test.rb fails if any span carries content.
module Ai::Instrumentation::MetadataTracing
  # Health probes carry no family data and aren't traced (docs/hosting/ai.md), so every span
  # started inside a probe call is dropped; any other span is sampled as the SDK's default does.
  class ProbeSampler
    DEFAULT = OpenTelemetry::SDK::Trace::Samplers.parent_based(root: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON)

    def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      return DEFAULT.should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:) unless probe?

      OpenTelemetry::SDK::Trace::Samplers::Result.new(decision: OpenTelemetry::SDK::Trace::Samplers::Decision::DROP,
                                                      tracestate: OpenTelemetry::Trace.current_span(parent_context).context.tracestate)
    end

    def description = "SureProbeSampler"

    private
      def probe? = Ai::CallContext.current&.feature == "probe"
  end

  module_function

  # The app owns the tracer provider and exporter, as RubyLLM's OpenTelemetry docs ask.
  def enable(endpoint: nil, headers: nil, processor: nil)
    processor ||= OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint:, headers: parse_headers(headers))
    )
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(sampler: ProbeSampler.new)
    provider.add_span_processor(processor)
    OpenTelemetry.tracer_provider = provider

    if RubyLLM::OpenTelemetry.method(:enable).parameters.any? { |_, name| name == :content }
      RubyLLM::OpenTelemetry.enable(content: false)
    else
      RubyLLM::OpenTelemetry.enable
    end
    provider
  end

  # OTLP_HEADERS uses the OpenTelemetry form: `key=value,key=value`, values percent-encoded.
  def parse_headers(value)
    value.to_s.split(",").filter_map do |pair|
      key, header = pair.split("=", 2).map { _1.to_s.strip }
      [ key, percent_decode(header) ] if key.present?
    end.to_h
  end

  # Percent-decoding only, as the OTLP exporter parses its own headers variable: a literal `+`
  # stays, since a value is RFC 3986 text, not form data, so a base64 credential keeps its
  # pluses. A malformed sequence stays as written rather than raising: the value is operator-set.
  def percent_decode(value)
    URI.decode_uri_component(value.to_s)
  rescue ArgumentError
    value.to_s
  end
end
