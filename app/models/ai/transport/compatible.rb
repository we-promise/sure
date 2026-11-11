# The OpenAI API, whoever runs it: OpenAI, Gemini's compatible API, OpenRouter,
# LiteLLM, llama.cpp, Ollama, vLLM, LM Studio, embedding servers and the external assistant.
class Ai::Transport::Compatible < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter
  include Ai::Transport::JsonMode

  # Document OCR services RubyLLM reaches with its own providers (`RubyLLM.ocr`): one page image
  # per request, because Cohere's Parse call takes one image, and so both bill and record per
  # page. Mistral's hasn't been run live.
  OCR_PRESETS = { mistral: "https://api.mistral.ai/v1", cohere: "https://api.cohere.com" }.freeze
  # Tokens llama-server leaks when started with --special, which OCR models' table tags need:
  # <｜end▁of▁sentence｜> and its kin.
  SPECIAL_TOKENS = /<｜[^｜<>]{1,40}｜>|<\|(?:im_end|endoftext|end)\|>/

  private
    def run_generate(request) = generate_with_json_mode(request)

    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model, timeout:)
      when :tools then probe_tools(model, timeout:)
      when :embedding then probe_embedding(model, timeout:)
      end
    end

    # Model listing stays on ruby-openai, built by Ai::Transport::Http: RubyLLM has no public
    # per-context model listing (Provider#list_models is :nodoc:).
    def probe_models(model, timeout:)
      response = mapping_errors { Ai::Transport::Http.openai_client(endpoint, timeout:).models.list }
      raise Ai::Error::InvalidOutput, "the models list has no data" unless response.is_a?(Hash) && response["data"].is_a?(Array)
      raise Ai::Error::InvalidOutput, "the models list has entries that aren't objects" unless response["data"].all?(Hash)

      ids = response["data"].filter_map { _1["id"] }
      # Ollama lists `llama3` as `llama3:latest`.
      unless ids.include?(model.name) || ids.include?("#{model.name}:latest")
        raise Ai::Error::ModelMissing, "#{model.name} isn't listed"
      end

      model.name
    end

    # Today's request: the model and the texts, no `dimensions` (a server that can't shorten
    # vectors would refuse it). RubyLLM sorts the rows by their index when the server sends one;
    # OpenAI-compatible servers answer in order.
    def run_embed(request)
      embedding = attempt do
        mapping_errors do
          ruby_llm_context.embed(request.texts, model: request.model.name, provider: ruby_llm_provider,
                                                assume_model_exists: true)
        end
      end
      vectors = checked_vectors!(request.model, embedding.vectors)
      EmbedResponse.new(vectors:, usage: Ai::Tokens.from_ruby_llm(embedding.tokens))
    end

    def run_ocr(request) = OCR_PRESETS.key?(endpoint.preset) ? ocr_by_page(request) : ocr_through_chat(request)

    def ocr_by_page(request)
      texts = request.pages.map do |page|
        result = attempt do
          mapping_errors do
            ruby_llm_context.ocr(RubyLLM::Attachment.new(StringIO.new(page.data), filename: page.filename),
                                 model: request.model.name, provider: endpoint.preset, assume_model_exists: true)
          end
        end
        result.markdown.to_s
      end
      OcrResponse.new(texts:, usage: Ai::Tokens.new)
    end

    # A vision model that transcribes, with its own prompt folder (Model#ocr_prompt): its
    # `instructions` are the last user message; its `input`, when the model's chat template wants
    # one message per page (Unlimited-OCR-2's "<PAGE>"), goes before each page. RubyLLM puts a
    # message's text before its files, so per-page messages are the only way to get that order.
    def ocr_through_chat(request)
      prompt = Ai::Prompt.for(:extract_pdf, default: "ocr_#{request.model.ocr_prompt || "markdown"}", route: nil, family: nil,
                                            locale: nil, locals: { pages: request.pages.size })
      chat = ruby_llm_chat(request.model)
      max_tokens = request.model.max_output_tokens
      chat.with_max_output_tokens(max_tokens) if max_tokens
      files = ruby_llm_attachments(request.pages)
      if prompt.input.strip.present?
        files.each { chat.add_message(role: :user, content: prompt.input.strip, attachments: [ _1 ]) }
        chat.add_message(role: :user, content: prompt.instructions.strip)
      else
        chat.add_message(role: :user, content: prompt.instructions.strip, attachments: files)
      end

      message = attempt { mapping_errors { chat.generate } }
      OcrResponse.new(texts: [ message.content.to_s.gsub(SPECIAL_TOKENS, "").strip ], usage: Ai::Tokens.from_ruby_llm(message.tokens))
    end

    # One vector, with the model's dimensions. RubyLLM's embed takes no headers
    # (crmne/ruby_llm#1556), so an endpoint that needs them is refused rather than probed
    # without them.
    def probe_embedding(model, timeout:)
      if Ai::Transport::Http.headers(endpoint).any?
        raise Ai::Error::Refused, "embedding requests can't carry the endpoint's static headers yet"
      end

      embedding = mapping_errors do
        ruby_llm_context(timeout:).embed(Ai::Transport::Base::PROBE_EMBEDDING_INPUT, model: model.name, provider: ruby_llm_provider,
                                                                       assume_model_exists: true)
      end
      checked_vectors!(model, embedding.vectors).first.size
    end

    # OpenRouter keeps its own RubyLLM provider: only it round-trips reasoning_details
    # (Gemini's thought signatures). Every other compatible server is :openai.
    def ruby_llm_provider = endpoint.preset == :openrouter ? :openrouter : :openai

    # Always explicit: RubyLLM's :openai provider defaults to the Responses API, a bare 404 on
    # other compatible servers.
    def ruby_llm_protocol = endpoint.responses_api ? :responses : :chat_completions

    # An OpenRouter endpoint without a URL is OpenRouter's, as for ruby-openai's client.
    def ruby_llm_api_base
      return endpoint.base_url.presence || OCR_PRESETS[endpoint.preset] if OCR_PRESETS.key?(endpoint.preset)

      base = endpoint.base_url.presence || (Ai::Transport::Http::OPENROUTER_BASE if ruby_llm_provider == :openrouter)
      Ai::Transport::Http.compatible_base(base)
    end

    def configure_provider(config)
      case endpoint.preset
      when :mistral
        config.mistral_api_key = endpoint.api_key
        config.mistral_api_base = ruby_llm_api_base
      when :cohere
        config.cohere_api_key = endpoint.api_key
        config.cohere_api_base = ruby_llm_api_base
      end
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
