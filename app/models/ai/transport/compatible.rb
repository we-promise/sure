# The OpenAI API, whoever runs it: OpenAI, Gemini's compatible API, OpenRouter,
# LiteLLM, llama.cpp, Ollama, vLLM, LM Studio, embedding servers and the external assistant.
class Ai::Transport::Compatible < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  private
    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model, timeout:)
      when :tools then probe_tools(model, timeout:)
      when :embedding then probe_embedding(model, timeout:)
      end
    end

    # Model listing stays on ruby-openai, built by Ai::Transport::Http: RubyLLM 2.1.1 has no
    # public per-context model listing (Provider#list_models is :nodoc:).
    def probe_models(model, timeout:)
      response = mapping_errors { Ai::Transport::Http.openai_client(endpoint, timeout:).models.list }
      raise Ai::Error::InvalidOutput, "the models list has no data" unless response.is_a?(Hash) && response["data"].is_a?(Array)
      raise Ai::Error::InvalidOutput, "the models list has entries that aren't objects" unless response["data"].all?(Hash)

      ids = response["data"].filter_map { _1["id"] }
      raise Ai::Error::ModelMissing, "#{model.name} isn't listed" unless ids.include?(model.name)

      model.name
    end

    # One vector per text, with the model's dimensions. RubyLLM 2.1.1 doesn't check the row
    # count itself (2.2 does, RubyLLM #1297).
    def probe_embedding(model, timeout:)
      embedding = mapping_errors do
        ruby_llm_context(timeout:).embed(Ai::Transport::Base::PROBE_EMBEDDING_INPUT, model: model.name, provider: ruby_llm_provider,
                                                                       assume_model_exists: true)
      rescue NoMethodError, TypeError => error
        raise unless raised_in_ruby_llm?(error)

        raise Ai::Error::InvalidOutput, "the embedding response isn't the expected shape"
      end
      vectors = embedding.vectors
      vectors = [ vectors ] if vectors.first.is_a?(Numeric)
      raise Ai::Error::InvalidOutput, "expected 1 vector, got #{vectors.size}" unless vectors.size == 1
      unless vectors.first.is_a?(Array) && vectors.first.all? { _1.is_a?(Numeric) && _1.finite? }
        raise Ai::Error::InvalidOutput, "the embedding has components that aren't finite numbers"
      end

      dimensions = vectors.first.size
      expected = model.embedding_dimensions
      raise Ai::Error::InvalidOutput, "expected #{expected} dimensions, got #{dimensions}" if expected && dimensions != expected

      dimensions
    end

    # OpenRouter keeps its own RubyLLM provider: only it round-trips reasoning_details
    # (Gemini's thought signatures). Every other compatible server is :openai.
    def ruby_llm_provider = endpoint.preset == :openrouter ? :openrouter : :openai

    # Always explicit: RubyLLM's :openai provider defaults to the Responses API, a bare 404 on
    # other compatible servers.
    def ruby_llm_protocol = endpoint.responses_api ? :responses : :chat_completions

    # An OpenRouter endpoint without a URL is OpenRouter's, as for ruby-openai's client.
    def ruby_llm_api_base
      base = endpoint.base_url.presence || (Ai::Transport::Http::OPENROUTER_BASE if ruby_llm_provider == :openrouter)
      Ai::Transport::Http.compatible_base(base)
    end

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
