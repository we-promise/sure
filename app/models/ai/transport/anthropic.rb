# Claude through the native Messages API (section 4.2); its OpenAI-compatible layer drops
# features.
class Ai::Transport::Anthropic < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  DEFAULT_BASE = "https://api.anthropic.com".freeze

  private
    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model)
      when :tools then probe_tools(model)
      when :embedding then raise Ai::Error::Refused, "Anthropic has no embedding models"
      end
    end

    # Through the anthropic gem, built by Ai::Transport::Http (RubyLLM 2.1.1 has no public
    # per-context model listing). The gem takes no proxy.
    def probe_models(model, timeout:)
      info = mapping_errors { anthropic_errors { Ai::Transport::Http.anthropic_client(endpoint, timeout:).models.retrieve(model.name) } }
      raise Ai::Error::ModelMissing, "#{model.name} isn't listed" unless info.respond_to?(:id) && info.id.present?

      info.id
    end

    def anthropic_errors
      yield
    rescue ::Anthropic::Errors::APITimeoutError => error
      raise Ai::Error::Timeout, error.message
    rescue ::Anthropic::Errors::APIStatusError => error
      raise Ai::Error.from_status(error.status, error.message, body: error.body)
    rescue ::Anthropic::Errors::APIConnectionError => error
      raise Ai::Error::Unreachable, error.message
    end

    def ruby_llm_provider = :anthropic
    def ruby_llm_protocol = nil
    def ruby_llm_api_base = endpoint.base_url.presence || DEFAULT_BASE

    def configure_provider(config)
      config.anthropic_api_key = endpoint.api_key
      config.anthropic_api_base = endpoint.base_url if endpoint.base_url.present?
    end
end
