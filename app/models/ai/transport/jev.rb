# Jev and other servers that speak TypeSafe's System One protocol, through RubyLLM's `judge`.
# TypeSafe-style `/v1/systemone` endpoints go through RubyLLM's `typesafe` provider; OpenRouter's
# Decisions gateway (`…/alpha/decisions`) goes through its `openrouter` provider, which is what
# posts there. Jev judges, it doesn't generate.
#
# Jev takes one state per request, and each request is latency-bound (~400-550 ms), so `judge`
# fans a batch out on a pool of the endpoint's `parallel_requests`: 8 for cloud Jev, and 1 for a
# self-hosted server, whose GPU or CPU 8 at once would overload. Above the transport it's one
# call, as for an LLM. Every request goes through RubyLLM and Sure's instrumenter, so it writes a
# usage row.
#
# On TypeSafe-style endpoints the `typesafe` provider posts `v1/systemone` at the endpoint's
# base_url; on the OpenRouter dialect the `openrouter` provider posts `../alpha/decisions`, which
# the api_base resolves back onto the decisions URL.
class Ai::Transport::Jev < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  DEFAULT_BASE = "https://api.typesafe.ai".freeze
  PATH = "/v1/systemone".freeze
  DEFAULT_PARALLEL_REQUESTS = { cloud: 8, local: 1 }.freeze

  def parallel_requests = endpoint.parallel_requests || DEFAULT_PARALLEL_REQUESTS.fetch(endpoint.location)

  private
    def run_judge(request)
      refuse_callables!(request.questions)
      results = in_parallel(request.states.to_a) do |id, state|
        [ id, *judge_one(request, state) ]
      end

      answers = results.to_h { |id, answer, _usage| [ id, answer ] }
      usage = results.map(&:last).compact.reduce { _1 + _2 }
      if answers.any? && answers.values.all?(&:nil?)
        raise Ai::Error::InvalidOutput, "every answer from #{request.model.name} was malformed"
      end

      JudgeResponse.new(answers:, usage:)
    end

    # One state's answers and usage. A malformed answer (an option not asked for, a choice with no
    # confidence) fails only that state: RubyLLM rejects the whole response, so its usage is lost
    # (crmne/ruby_llm#1614).
    def judge_one(request, state)
      judgment = attempt do
        mapping_errors do
          ruby_llm_context.judge(state, questions: request.questions, model: request.model.name,
                                        provider: ruby_llm_provider, assume_model_exists: true)
        end
      end
      [ judgment.answers.to_h { |name, answer| [ name.to_sym, answer ] }, Ai::Tokens.from_ruby_llm(judgment.tokens) ]
    rescue Ai::Error::InvalidOutput => error
      Rails.logger.warn("[Ai::Transport::Jev] #{error.message}")
      [ nil, nil ]
    end

    # Questions are plain data by design, so a Proc is a caller's bug.
    def refuse_callables!(value)
      case value
      when Proc then raise ArgumentError, "Jev questions must be plain data, not a Proc"
      when Hash then value.each_value { refuse_callables!(_1) }
      when Array then value.each { refuse_callables!(_1) }
      end
    end

    # A fixed pool over the states. `value!` re-raises a request's error, so a failover error ends
    # the call. Each thread runs in the executor, because it can write usage rows.
    def in_parallel(items)
      return [] if items.empty?

      pool = Concurrent::FixedThreadPool.new([ parallel_requests, items.size ].min)
      begin
        items.map { |item| Concurrent::Promises.future_on(pool) { Rails.application.executor.wrap { yield(item) } } }
             .map(&:value!)
      ensure
        pool.shutdown
        pool.wait_for_termination
      end
    end

    def run_probe(_model, _check, timeout:)
      raise Ai::Error::Refused, "Jev has no health probe yet"
    end

    def ruby_llm_provider = endpoint.preset == :jev_openrouter ? :openrouter : :typesafe
    def ruby_llm_protocol = nil
    def ruby_llm_api_base = endpoint.base_url.presence || DEFAULT_BASE

    def configure_provider(config)
      if ruby_llm_provider == :openrouter
        config.openrouter_api_key = endpoint.api_key.presence || "none"   # RubyLLM requires one
        config.openrouter_api_base = ruby_llm_api_base
        config.openrouter_app_name = OPENROUTER_APP_NAME
        config.openrouter_app_url = OPENROUTER_APP_URL
      else
        config.typesafe_api_key = endpoint.api_key.presence || "none"   # RubyLLM requires one; a local server may ignore it
        config.typesafe_api_base = ruby_llm_api_base
      end
    end
end
