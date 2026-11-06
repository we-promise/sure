# The OpenAI API, whoever runs it (section 4.2): OpenAI, Gemini's compatible API, OpenRouter,
# LiteLLM, llama.cpp, Ollama, vLLM, LM Studio, embedding servers and the external assistant.
class Ai::Transport::Compatible < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter
  include Ai::Transport::JsonMode

  private
    def run_generate(request) = generate_with_json_mode(request)

    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model)
      when :tools then probe_tools(model)
      when :embedding then probe_embedding(model)
      end
    end

    # Model listing stays on ruby-openai, built by Ai::Transport::Http: RubyLLM 2.1.1 has no
    # public per-context model listing (Provider#list_models is :nodoc:).
    def probe_models(model, timeout:)
      response = mapping_errors { Ai::Transport::Http.openai_client(endpoint, timeout:).models.list }
      raise Ai::Error::InvalidOutput, "the models list has no data" unless response.is_a?(Hash) && response["data"].is_a?(Array)

      ids = response["data"].filter_map { _1["id"] || _1[:id] }
      raise Ai::Error::ModelMissing, "#{model.name} isn't listed" unless ids.include?(model.name)

      model.name
    end

    # Today's request: the model and the texts, no `dimensions` (a server that can't shorten
    # vectors would refuse it). RubyLLM 2.1.1 keeps the rows in the server's order (#1160 sorts
    # by index after 2.1.1); OpenAI-compatible servers answer in order.
    def run_embed(request)
      embedding = attempt do
        mapping_errors do
          ruby_llm_context.embed(request.texts, model: request.model.name, provider: ruby_llm_provider,
                                                task_type: request.task_type, assume_model_exists: true)
        end
      end
      vectors = checked_vectors!(request.model, embedding.vectors, request.texts.size)
      EmbedResponse.new(vectors:, usage: Ai::Tokens.from_ruby_llm(embedding.tokens))
    end

    # One vector, with the model's dimensions.
    def probe_embedding(model)
      embedding = mapping_errors do
        ruby_llm_context.embed(Ai::Transport::Base::PROBE_EMBEDDING_INPUT, model: model.name, provider: ruby_llm_provider,
                                                                       assume_model_exists: true)
      end
      checked_vectors!(model, embedding.vectors, 1).first.size
    end

    # OpenRouter keeps its own RubyLLM provider: only it round-trips reasoning_details
    # (Gemini's thought signatures). Every other compatible server is :openai.
    def ruby_llm_provider = endpoint.preset == :openrouter ? :openrouter : :openai

    # Always explicit: RubyLLM's :openai provider defaults to the Responses API, a bare 404 on
    # other compatible servers.
    def ruby_llm_protocol = endpoint.responses_api ? :responses : :chat_completions

    def ruby_llm_api_base = Ai::Transport::Http.compatible_base(endpoint.base_url)

    def configure_provider(config)
      config.openai_use_system_role = true   # both providers read it; otherwise system prompts go as "developer"
      if ruby_llm_provider == :openrouter
        config.openrouter_api_key = endpoint.api_key
        config.openrouter_api_base = ruby_llm_api_base if endpoint.base_url.present?
        config.openrouter_app_name = OPENROUTER_APP_NAME   # RubyLLM otherwise sends "RubyLLM"
        config.openrouter_app_url = OPENROUTER_APP_URL
      else
        config.openai_api_key = endpoint.api_key.presence || "none"   # RubyLLM requires one; local servers ignore it
        config.openai_api_base = ruby_llm_api_base
      end
    end
end
