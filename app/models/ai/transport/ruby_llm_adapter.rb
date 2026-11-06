# What the RubyLLM transports share: one RubyLLM context per endpoint, errors mapped onto
# Ai::Error, and the probe calls. Only RubyLLM's public API is used (context, chat, generate,
# the with_* setters, embed, Tool), so an upgrade can't break Sure through a private method.
module Ai::Transport::RubyLlmAdapter
  OPENROUTER_APP_NAME = "Sure".freeze
  OPENROUTER_APP_URL = "https://sure.am".freeze

  private
    # Settings RubyLLM would otherwise choose (spike: "Small fixes in Sure's adapter"):
    # - request_timeout from the endpoint (RubyLLM's default is 300 s per read);
    # - max_retries 0: Sure retries itself (Ai::Transport::Base#attempt);
    # - the proxy from Ai::Transport::Http, for every provider;
    # - no upload of large files to a provider's Files API, where a statement would stay;
    # - Sure's instrumenter, which every request passes (the attempt budget; PR 4's gate).
    def ruby_llm_context
      @ruby_llm_context ||= RubyLLM.context do |config|
        config.request_timeout = endpoint.timeout_seconds
        config.max_retries = 0
        config.http_proxy = Ai::Transport::Http.proxy_for(ruby_llm_api_base)
        config.auto_upload_large_files = false
        config.instrumenter = Ai::Transport::Instrumenter.new(config.instrumenter)
        configure_provider(config)
      end
    end

    def ruby_llm_chat(model)
      ruby_llm_context
        .chat(model: model.name, provider: ruby_llm_provider, protocol: ruby_llm_protocol, assume_model_exists: true)
        .with_headers(Ai::Transport::Http.headers(endpoint))
    end

    def probe_chat(model)
      chat = ruby_llm_chat(model).with_max_output_tokens(Ai::Transport::Base::PROBE_MAX_OUTPUT_TOKENS)
      chat.add_message(role: :user, content: Ai::Transport::Base::PROBE_PROMPT)
      message = mapping_errors { chat.generate }
      check_answering_model!(model.name, message.model)
      message.content.to_s
    end

    def probe_tools(model)
      chat = ruby_llm_chat(model)
               .with_max_output_tokens(Ai::Transport::Base::PROBE_TOOL_MAX_OUTPUT_TOKENS)
               .with_tools(ProbeTool.new)
      chat.add_message(role: :user, content: Ai::Transport::Base::PROBE_TOOL_PROMPT)
      message = mapping_errors { chat.generate }
      tool_calls(message).any? { _1.name == Ai::Transport::Base::PROBE_TOOL_NAME }
    end

    # A Hash keyed by call id on 2.1.1, a collection of ToolCall on 2.2 (#1380).
    def tool_calls(message)
      calls = message.tool_calls
      calls = calls.values if calls.is_a?(Hash)
      Array(calls)
    end

    # Providers often quote the request, and sometimes the key, back in an error, so every
    # mapped error's message is scrubbed here, before anything logs or instruments it.
    def mapping_errors
      yield
    rescue Ai::Error::Base => error
      raise scrubbed(error)
    rescue ArgumentError => error
      # RubyLLM 2.2 raises ArgumentError for an option a protocol can't carry (#1379, #1382):
      # a request Sure built wrong, which every model would refuse.
      raise scrubbed(Ai::Error::Refused.new(error.message))
    rescue StandardError => error
      mapped = ruby_llm_error(error)
      raise mapped ? scrubbed(mapped) : error
    end

    def scrubbed(error)
      message = Ai::Instrumentation::Redactor.scrub(error.message, secrets: [ endpoint.api_key ])
      return error if message == error.message

      error.class.new(message, status: error.status).tap { _1.set_backtrace(error.backtrace) if error.backtrace }
    end

    def ruby_llm_error(error)
      status = error.respond_to?(:response) && error.response.respond_to?(:status) ? error.response.status : nil
      body = error.respond_to?(:response) && error.response.respond_to?(:body) ? error.response.body : nil
      text = [ error.message, body.is_a?(String) ? body : body.to_json ].join(" ")

      klass =
        case error
        when RubyLLM::PaymentRequiredError then Ai::Error::NoCredit
        when RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError then Ai::Error::Unauthorized
        when RubyLLM::RateLimitError then Ai::Error::NO_CREDIT.any? { text.match?(_1) } ? Ai::Error::NoCredit : Ai::Error::RateLimited
        when RubyLLM::ContextLengthExceededError then Ai::Error::ContextTooLong
        when RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError then Ai::Error::Upstream
        when RubyLLM::CancelledError then Ai::Error::Cancelled
        when RubyLLM::ModelNotFoundError then Ai::Error::ModelMissing   # not a RubyLLM::Error
        end
      klass ||= connection_error_class(error)
      return klass.new(error.message, status:) if klass

      return Ai::Error.from_status(status || 400, error.message, body:) if error.is_a?(RubyLLM::Error)

      Ai::Error.from_exception(error)
    end

    # RubyLLM 2.2 raises RubyLLM::ConnectionError (with `timeout?`) where 2.1.1 lets Faraday's
    # errors through (#1407); Ai::Error.from_exception handles the 2.1.1 ones.
    def connection_error_class(error)
      return unless defined?(RubyLLM::ConnectionError) && error.is_a?(RubyLLM::ConnectionError)

      error.respond_to?(:timeout?) && error.timeout? ? Ai::Error::Timeout : Ai::Error::Unreachable
    end

    # Declared to the model, never run: `Chat#generate` makes one request and doesn't run tools.
    class ProbeTool < RubyLLM::Tool
      description "Records the result of a Sure health check. Always call this tool."
      parameters Ai::Transport::Base::PROBE_TOOL_SCHEMA

      def name = Ai::Transport::Base::PROBE_TOOL_NAME
      def execute(status:) = raise(Ai::Error::Refused, "the health check tool is never run (#{status})")
    end
end
