# The transport interface: health probes (AiHealth::Probe) and structured generation
# (Ai::Generation), with retries and one `.ai` event per call.
class Ai::Transport::Base
  # One structured-output request. `failed_ratio` (optional) takes the parsed JSON and returns
  # the share of items the model left blank or missed, for `auto` JSON mode's fallback; nil
  # means blanks are a normal answer (bill setup).
  Request = Data.define(:feature, :family, :model, :instructions, :input, :schema, :schema_name, :max_tokens,
                        :reasoning_effort, :json_mode, :failed_ratio) do
    def initialize(feature:, model:, instructions:, input:, schema:, schema_name:, family: nil, max_tokens: nil,
                   reasoning_effort: nil, json_mode: :auto, failed_ratio: nil)
      super(feature: feature.to_sym, family:, model:, instructions:, input:, schema:, schema_name: schema_name.to_s,
            max_tokens:, reasoning_effort: reasoning_effort&.to_s, json_mode: json_mode.to_sym, failed_ratio:)
    end

    # What the `.ai` event records: never the family's data beyond what the prompt holds.
    def to_event = { instructions:, input:, schema_name:, json_mode:, reasoning_effort:, max_tokens: }.compact
  end

  # The parsed JSON (a Hash or an Array), the summed usage of every request the call made, and
  # the JSON mode that produced it.
  Response = Data.define(:json, :usage, :raw_id, :finish_reason, :json_mode)

  # `auto` moves on when more than this share of items came back blank or missing.
  BLANK_RATIO_LIMIT = 0.5
  # Health checks a probe can make. Which one AiHealth runs for "is the model up" is the
  # endpoint's `probe_check`; tools and embedding are their own probes.
  PROBE_CHECKS = %i[models chat tools embedding].freeze
  PROBE_PROMPT = "Reply with OK.".freeze
  PROBE_TOOL_PROMPT = "Call the sure_health_check tool with status set to ok.".freeze
  PROBE_TOOL_NAME = "sure_health_check".freeze
  PROBE_TOOL_SCHEMA = {
    type: "object",
    properties: { status: { type: "string", description: "Always the literal string \"ok\"." } },
    required: [ "status" ],
    additionalProperties: false
  }.freeze
  PROBE_EMBEDDING_INPUT = "Sure AI health check".freeze
  PROBE_MAX_OUTPUT_TOKENS = 16
  PROBE_TOOL_MAX_OUTPUT_TOKENS = 256
  # What a provider may add to a model's name for a dated snapshot of it.
  SNAPSHOT_SUFFIX = /\A-(?:\d{4}-\d{2}-\d{2}|\d{8}|\d{4})\z/

  attr_reader :endpoint

  def initialize(endpoint)
    @endpoint = endpoint
  end

  # Sends one structured-output request and returns a Response, or raises an Ai::Error. The
  # whole call, with its retries and JSON-mode fallbacks, has one time budget: the endpoint's
  # timeout, so a slow model can't multiply it.
  def generate(request)
    Ai::CallContext.call(feature: request.feature, model: request.model, family: request.family, budget: endpoint.timeout_seconds) do
      instrument("generate", model: request.model, request: request.to_event) { run_generate(request) }
    end
  end

  # Health probes reuse the production path, so they can't drift from it: the same client settings,
  # headers, timeout, proxy and error mapping. Returns what the check found, or raises an
  # Ai::Error:
  #   :models    -> the model's id, when the server lists it (no chat call);
  #   :chat      -> the answer's text, after checking the model that answered;
  #   :tools     -> true when the model called the test tool, false when it answered in text;
  #   :embedding -> the embedding's dimensions.
  def probe(model, check, timeout: endpoint.timeout_seconds)
    raise ArgumentError, "unknown probe check #{check.inspect}" unless PROBE_CHECKS.include?(check)

    Ai::CallContext.call(feature: :probe, model:, budget: timeout) do
      instrument("probe", model:, request: { check: }) { attempt { run_probe(model, check, timeout:) } }
    end
  end

  private
    def run_probe(model, check, timeout:) = raise(NotImplementedError)
    def run_generate(request) = raise(NotImplementedError)

    # Tolerant parsing, the one copy of what each worker did: a reasoning model's
    # <think> block, fenced JSON (closed or not), prose around the object, or a bare array.
    # Returns a Hash or an Array, or nil when nothing parses.
    def parse_json(text)
      return if text.blank?

      cleaned = strip_thinking(text.to_s)
      fenced = cleaned.scan(/```(?:json)?\s*([\[{][\s\S]*?[\]}])\s*```/m).flatten.reverse
      unclosed = cleaned[/```(?:json)?\s*([\[{][\s\S]*[\]}])\s*\z/m, 1]
      object = cleaned[/\{[\s\S]*\}/m]
      array = cleaned[/\[[\s\S]*\]/m]

      [ cleaned, *fenced, unclosed, object, array ].compact.each do |candidate|
        parsed = JSON.parse(candidate)
        return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
      rescue JSON::ParserError
        next
      end
      nil
    end

    # The answer after a closed <think> block; with no close (a cut-off model), what's inside it.
    def strip_thinking(text)
      return text unless text.include?("<think>")

      after = text[%r{</think>\s*([\s\S]*)}m, 1]
      return after if after.present?

      text[/<think>([\s\S]*)/m, 1] || text
    end

    # RubyLLM's finish reasons for "stopped at the output limit": :length on the OpenAI
    # protocols, :max_tokens on Anthropic's.
    def cut_at_limit?(finish_reason) = %i[length max_tokens].include?(finish_reason&.to_sym)

    # Sure retries, not RubyLLM: RubyLLM has no hook before a retry, so only here can a spent
    # balance (OpenAI's 429 insufficient_quota) stop retrying and the attempt budget, wait
    # included, be checked between tries.
    def attempt
      tries = 0
      begin
        tries += 1
        yield
      rescue *Ai::Error::RETRYABLE => error
        delay = retry_delay(tries)
        remaining = Ai::CallContext.current&.remaining
        raise if tries > endpoint.max_retries || (remaining && remaining <= delay)

        sleep(delay)
        retry
      end
    end

    def retry_delay(tries) = [ 0.5 * (2**(tries - 1)), 8 ].min * (0.75 + rand * 0.5)

    # One `.ai` event per call, carrying what subscribers need: the route, the
    # request (files by name and size, never their bytes), the output, usage and error class.
    def instrument(name, model:, request:)
      call = Ai::CallContext.current
      payload = { feature: call&.feature, call_id: call&.call_id, correlation_id: call&.correlation_id,
                  family_id: call&.family_id, endpoint: endpoint.to_event, route: model.to_event, request:,
                  scrub: scrubber }

      ActiveSupport::Notifications.instrument("#{name}.ai", payload) do
        result = yield
        payload[:output] = result.is_a?(Response) ? result.json : result
        payload[:usage] = result.usage if result.is_a?(Response)
        payload[:json_mode] = result.json_mode if result.is_a?(Response)
        result
      rescue Ai::Error::Base => error
        payload[:error] = error.class.name
        payload[:error_message] = Ai::Instrumentation::Redactor.scrub(error.message, secrets: endpoint.secrets)
        payload[:http_status] = error.status
        raise
      end
    end

    # Scrubs a string of this endpoint's key and header values, for a subscriber that sends
    # content elsewhere. A function, so the payload never holds the secrets themselves.
    def scrubber
      secrets = endpoint.secrets
      ->(text) { Ai::Instrumentation::Redactor.scrub(text, secrets:) }
    end

    # The model that answered differs from the one asked for: LM Studio answers a request for a
    # model it doesn't have with whichever model is loaded, and a 200.
    def check_answering_model!(asked, answered)
      return if answered.blank? || same_model?(asked, answered)

      raise Ai::Error::ModelMissing, "asked for #{asked}, but #{answered} answered"
    end

    # The same model under a vendor prefix (openai/gpt-4.1), a snapshot date (gpt-4.1-2025-04-14,
    # claude-sonnet-4-5-20250929, gpt-4-0613) or for a `latest` alias. Any other difference is
    # another model: gpt-4.1-mini isn't gpt-4.1, nor gpt-4o gpt-4.
    def same_model?(asked, answered)
      short, long = [ asked, answered ].map { model_stem(_1) }.minmax_by(&:length)
      short == long || (long.start_with?(short) && long.delete_prefix(short).match?(SNAPSHOT_SUFFIX))
    end

    def model_stem(name) = name.to_s.downcase.split("/").last.to_s.delete_suffix(":latest").delete_suffix("-latest")
end
