# Claude through the native Messages API; its OpenAI-compatible layer drops
# features.
class Ai::Transport::Anthropic < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  DEFAULT_BASE = "https://api.anthropic.com".freeze
  API_VERSION = "2023-06-01".freeze

  private
    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model, timeout:)
      when :tools then probe_tools(model, timeout:)
      when :embedding then raise Ai::Error::Refused, "Anthropic has no embedding models"
      end
    end

    # RubyLLM 2.1.1 has no public per-context model listing, so this is a plain GET through
    # Faraday with Ai::Transport::Http's proxy and TLS options, as every other call gets. The
    # anthropic gem, used here before, reads only HTTP_PROXY: live, it went direct when only
    # HTTPS_PROXY was set, so the probe checked a different path from the calls it vouches for.
    def probe_models(model, timeout:)
      url = "#{ruby_llm_api_base.delete_suffix("/")}/v1/models/#{ERB::Util.url_encode(model.name)}"
      mapping_errors do
        response = Ai::Transport::Http.faraday(url, timeout:).get(url) do |request|
          request.headers.update(Ai::Transport::Http.headers(endpoint))
          request.headers["x-api-key"] = endpoint.api_key.to_s
          request.headers["anthropic-version"] = API_VERSION
        end
        body = JSON.parse(response.body.to_s) rescue nil
        raise models_error(response.status, body) unless response.success?
        raise Ai::Error::InvalidOutput, "the model lookup didn't answer with JSON" unless body.is_a?(Hash)
        raise Ai::Error::ModelMissing, "#{model.name} isn't listed" if body["id"].blank?

        check_answering_model!(model.name, body["id"])   # a gateway may answer with another model
        body["id"]
      end
    end

    # Anthropic answers an unknown model with a 404 `not_found_error` whose message is
    # "model: <name>"; any other 404 (a wrong base URL, a gateway's own page) maps by its status.
    # A body that isn't Anthropic's error shape still maps by its status.
    def models_error(status, body)
      error = body.is_a?(Hash) ? body["error"] : nil
      type, message = error.is_a?(Hash) ? error.values_at("type", "message") : [ nil, error&.to_s ]
      message = message.presence || "HTTP #{status}"
      return Ai::Error::ModelMissing.new(message, status:) if status == 404 && type == "not_found_error" && message.start_with?("model:")

      Ai::Error.from_status(status, message, body:)
    end

    def ruby_llm_provider = :anthropic
    def ruby_llm_protocol = nil
    def ruby_llm_api_base = endpoint.base_url.presence || DEFAULT_BASE

    def configure_provider(config)
      config.anthropic_api_key = endpoint.api_key
      config.anthropic_api_base = endpoint.base_url if endpoint.base_url.present?
    end
end
