# What the RubyLLM transports share: one RubyLLM context per endpoint, errors mapped onto
# Ai::Error, and the probe calls. Only RubyLLM's public API is used (context, chat, generate,
# the with_* setters, embed, Tool), so an upgrade can't break Sure through a private method.
module Ai::Transport::RubyLlmAdapter
  OPENROUTER_APP_NAME = "Sure".freeze
  OPENROUTER_APP_URL = "https://sure.am".freeze
  RUBY_LLM_PATH = Gem.loaded_specs.fetch("ruby_llm").full_gem_path.freeze
  ARITY_ERROR = /wrong number of arguments|(?:missing|unknown) keywords?/

  private
    # Settings RubyLLM would otherwise choose:
    # - request_timeout from the endpoint, or the probe's own (RubyLLM's default is 300 s per read);
    # - max_retries 0: Sure retries itself (Ai::Transport::Base#attempt);
    # - the proxy and TLS settings from Ai::Transport::Http, for every provider;
    # - no upload of large files to a provider's Files API, where a statement would stay;
    # - Sure's instrumenter, which every request passes (the attempt budget, each failed request's error).
    def ruby_llm_context(timeout: endpoint.timeout_seconds)
      @ruby_llm_contexts ||= {}
      @ruby_llm_contexts[timeout] ||= RubyLLM.context do |config|
        config.request_timeout = timeout
        config.max_retries = 0
        config.http_proxy = Ai::Transport::Http.proxy_for(ruby_llm_api_base)
        config.faraday_adapter = Ai::Transport::Http.ruby_llm_adapter
        config.auto_upload_large_files = false
        config.instrumenter = Ai::Transport::Instrumenter.new(config.instrumenter, map_error: method(:mapped_error), scrub: scrubber)
        configure_provider(config)
      end
    end

    def ruby_llm_chat(model, timeout: endpoint.timeout_seconds)
      ruby_llm_context(timeout:)
        .chat(model: model.name, provider: ruby_llm_provider, protocol: ruby_llm_protocol, assume_model_exists: true)
        .with_headers(Ai::Transport::Http.headers(endpoint))
    end

    # One completion for a generation, without running tools (`Chat#generate`). The schema
    # goes through `with_schema` on every protocol: `response_format` on
    # chat completions and the Responses API, Anthropic's native `output_config`. Returns
    # [text, Ai::Tokens, raw id, finish reason].
    def complete_json(request, schema: true, response_format: nil, effort: nil, provider_options: {})
      chat = ruby_llm_chat(request.model).with_instructions(request.instructions)
      max_tokens = request.max_tokens || request.model.max_output_tokens
      chat.with_max_output_tokens(max_tokens) if max_tokens
      chat.with_schema(name: request.schema_name, schema: request.schema, strict: true) if schema
      chat.with_thinking(effort:) if effort
      options = provider_options.merge(response_format ? { response_format: } : {})
      chat.with_provider_options(options) if options.any?
      chat.add_message(role: :user, content: request.input, attachments: ruby_llm_attachments(request.attachments).presence)

      message = mapping_errors { chat.generate }
      [ message.content.to_s, Ai::Tokens.from_ruby_llm(message.tokens), raw_id(message), message.finish_reason ]
    end

    # Files inline, page images at high detail: today's OpenAI path sent `detail: "low"`, which
    # shrinks a page to 512 pixels. A fresh StringIO each time, because RubyLLM
    # reads the source once per request and a retry sends it again.
    def ruby_llm_attachments(attachments)
      attachments.map do |file|
        RubyLLM::Attachment.new(StringIO.new(file.data), filename: file.filename, resolution: (:high if file.image?))
      end
    end

    def raw_id(message)
      body = message.raw.respond_to?(:body) ? message.raw.body : nil
      body.is_a?(Hash) ? body["id"] : nil
    end

    # A parsed answer, or the error that ends the call: an answer cut at the output limit is
    # OutputCut (the generation splits the batch), parseable or not; anything else unparseable is
    # InvalidOutput.
    def parsed!(text, finish_reason, json_mode)
      # Checked first: a list cut short can still parse, and would drop the items it never reached.
      raise Ai::Error::OutputCut, "the answer stopped at the output limit (#{json_mode})" if cut_at_limit?(finish_reason)

      json = parse_json(text)
      return json if json

      raise Ai::Error::InvalidOutput, "the answer isn't JSON (#{json_mode})"
    end

    def probe_chat(model, timeout: endpoint.timeout_seconds)
      chat = ruby_llm_chat(model, timeout:).with_max_output_tokens(Ai::Transport::Base::PROBE_MAX_OUTPUT_TOKENS)
      chat.add_message(role: :user, content: Ai::Transport::Base::PROBE_PROMPT)
      message = mapping_errors { chat.generate }
      check_answering_model!(model.name, message.model)
      message.content.to_s
    end

    def probe_tools(model, timeout: endpoint.timeout_seconds)
      chat = ruby_llm_chat(model, timeout:)
               .with_max_output_tokens(Ai::Transport::Base::PROBE_TOOL_MAX_OUTPUT_TOKENS)
               .with_tools(ProbeTool.new)
      chat.add_message(role: :user, content: Ai::Transport::Base::PROBE_TOOL_PROMPT)
      message = mapping_errors { chat.generate }
      check_answering_model!(model.name, message.model)
      tool_calls(message).any? { _1.name == Ai::Transport::Base::PROBE_TOOL_NAME }
    end

    # A Hash keyed by call id on 2.1.1, a collection of ToolCall on 2.2 (RubyLLM #1380).
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
      raise unless refused_by_ruby_llm?(error)

      raise scrubbed(Ai::Error::Refused.new(error.message))
    rescue NoMethodError, TypeError => error
      # RubyLLM parsing a 200 that isn't the API's shape (`{}`, an HTML page); in Sure's own code it's a bug.
      raise unless raised_in_ruby_llm?(error)

      raise Ai::Error::InvalidOutput, "the response isn't the expected shape"
    rescue StandardError => error
      mapped = ruby_llm_error(error)
      raise mapped ? scrubbed(mapped) : error
    end

    # RubyLLM 2.2 raises ArgumentError for an option a protocol can't carry (RubyLLM #1379, #1382):
    # a request every model would refuse. Any other ArgumentError, such as a wrong call from Sure's
    # own code, is a bug and stays one.
    def refused_by_ruby_llm?(error)
      raised_in_ruby_llm?(error) && !error.message.match?(ARITY_ERROR)
    end

    def raised_in_ruby_llm?(error) = error.backtrace_locations&.first&.path.to_s.start_with?(RUBY_LLM_PATH)

    # A raised error as mapping_errors would raise it, or nil when it has no Ai::Error.
    def mapped_error(error)
      mapped = error.is_a?(Ai::Error::Base) ? error : ruby_llm_error(error)
      scrubbed(mapped) if mapped
    end

    def scrubbed(error)
      message = Ai::Instrumentation::Redactor.scrub(error.message, secrets: endpoint.secrets)
      return error if message == error.message

      error.class.new(message, status: error.status).tap { _1.set_backtrace(error.backtrace) if error.backtrace }
    end

    def ruby_llm_error(error)
      status = error.respond_to?(:response) && error.response.respond_to?(:status) ? error.response.status : nil
      body = error.respond_to?(:response) && error.response.respond_to?(:body) ? error.response.body : nil

      klass =
        case error
        when RubyLLM::PaymentRequiredError then Ai::Error::NoCredit
        when RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError then Ai::Error::Unauthorized
        when RubyLLM::RateLimitError then Ai::Error.for_status(429, error.message, body:)
        when RubyLLM::ContextLengthExceededError then Ai::Error::ContextTooLong
        when RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
          Ai::Error.for_status(status || 500, error.message, body:)
        when RubyLLM::CancelledError then Ai::Error::Cancelled
        when RubyLLM::ModelNotFoundError then Ai::Error::ModelMissing   # not a RubyLLM::Error
        end
      klass ||= connection_error_class(error)
      return klass.new(error.message, status:) if klass

      return Ai::Error::ModelMissing.new(error.message, status:) if missing_model?(status, body)
      return Ai::Error.from_status(status || 400, error.message, body:) if error.is_a?(RubyLLM::Error)

      Ai::Error.from_exception(error)
    end

    # Anthropic answers an unknown model with a 404 `not_found_error` whose message is
    # "model: <name>"; any other 404 (a wrong base URL, a gateway's own page) maps by its status.
    def missing_model?(status, body)
      body = JSON.parse(body) rescue nil if body.is_a?(String)
      error = body.is_a?(Hash) ? body["error"] : nil
      status == 404 && error.is_a?(Hash) && error["type"] == "not_found_error" && error["message"].to_s.start_with?("model:")
    end

    # RubyLLM 2.2 raises RubyLLM::ConnectionError (with `timeout?`) where 2.1.1 lets Faraday's
    # errors through (RubyLLM #1407); Ai::Error.from_exception handles the 2.1.1 ones.
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
