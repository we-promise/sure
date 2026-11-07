# The transport interface (section 7). A transport call arrives with its first caller: 2a
# implements `probe` (AiHealth::Probe); `generate` comes in 2c, `judge` in 2d, `embed` in 2e
# and `converse` in PR 6.
class Ai::Transport::Base
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

  def generate(request)            = raise NotImplementedError, "#{self.class.name}#generate arrives in PR 2c"
  def converse(request, &on_chunk) = raise NotImplementedError, "#{self.class.name}#converse arrives in PR 6"
  def judge(state:, questions:)    = raise NotImplementedError, "#{self.class.name}#judge arrives in PR 2d"
  def embed(texts, model:)         = raise NotImplementedError, "#{self.class.name}#embed arrives in PR 2e"

  # Health probes reuse the production path (fixes drift bug 6): the same client settings,
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

    # Sure retries, not RubyLLM (whose contexts all have max_retries 0): RubyLLM retries inside
    # one `request.ruby_llm`, with no hook before a retry, so only here can a spent balance
    # (OpenAI's 429 insufficient_quota) stop the retries and the attempt budget be checked
    # between tries. Each try is one HTTP request and one `usage.ruby_llm` event.
    def attempt
      tries = 0
      begin
        tries += 1
        yield
      rescue *Ai::Error::RETRYABLE => error
        raise if tries > endpoint.max_retries || Ai::CallContext.current&.expired?

        sleep(retry_delay(tries, error))
        retry
      end
    end

    def retry_delay(tries, _error) = [ 0.5 * (2**(tries - 1)), 8 ].min * (0.75 + rand * 0.5)

    # One `.ai` event per call (section 10), carrying what subscribers need: the route, the
    # request (files by name and size, never their bytes), the output, usage and error class.
    def instrument(name, model:, request:)
      call = Ai::CallContext.current
      payload = { feature: call&.feature, call_id: call&.call_id, correlation_id: call&.correlation_id,
                  family_id: call&.family_id, endpoint: endpoint.to_event, route: model.to_event, request: }

      ActiveSupport::Notifications.instrument("#{name}.ai", payload) do
        result = yield
        payload[:output] = result
        result
      rescue Ai::Error::Base => error
        payload[:error] = error.class.name
        payload[:error_message] = Ai::Instrumentation::Redactor.scrub(error.message, secrets: endpoint.secrets)
        payload[:http_status] = error.status
        raise
      end
    end

    def event_attachments(attachments) = Array(attachments).map { { filename: _1.filename, bytes: _1.data.bytesize } }

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
