# Claude through the native Messages API (section 4.2); its OpenAI-compatible layer drops
# features.
class Ai::Transport::Anthropic < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  DEFAULT_BASE = "https://api.anthropic.com".freeze
  API_VERSION = "2023-06-01".freeze

  private
    def run_probe(model, check, timeout:)
      case check
      when :models then probe_models(model, timeout:)
      when :chat then probe_chat(model)
      when :tools then probe_tools(model)
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
        body = JSON.parse(response.body.to_s) rescue {}
        raise Ai::Error.from_status(response.status, body.dig("error", "message"), body:) unless response.success?
        raise Ai::Error::ModelMissing, "#{model.name} isn't listed" if body["id"].blank?

        body["id"]
      end
    end

    def ruby_llm_provider = :anthropic
    def ruby_llm_protocol = nil
    def ruby_llm_api_base = endpoint.base_url.presence || DEFAULT_BASE

    def configure_provider(config)
      config.anthropic_api_key = endpoint.api_key
      config.anthropic_api_base = endpoint.base_url if endpoint.base_url.present?
    end
end
