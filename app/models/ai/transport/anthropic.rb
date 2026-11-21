# Claude through the native Messages API; its OpenAI-compatible layer drops
# features.
class Ai::Transport::Anthropic < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  DEFAULT_BASE = "https://api.anthropic.com".freeze
  API_VERSION = "2023-06-01".freeze
  # Anthropic's structured outputs refuse these: they go into the field's description instead,
  # and Ai::Schema still enforces them on the answer.
  NUMERIC_LIMITS = %i[minimum maximum multipleOf].freeze

  private
    # One request with the schema as Anthropic's native structured output (`output_config`),
    # which RubyLLM's `with_schema` sends. No tool, so no forced or `auto` tool choice and no
    # reminder retry (#4178, #4513). Reasoning effort isn't sent.
    def run_generate(request)
      native = request.with(schema: native_schema(request.schema))
      text, usage, finish_reason = attempt { complete_json(native) }
      json = parsed!(text, finish_reason, :schema)
      Response.new(json:, usage:, finish_reason:, json_mode: :schema)
    end

    def native_schema(node)
      return node.map { native_schema(_1) } if node.is_a?(Array)
      return node unless node.is_a?(Hash)

      rest = node.transform_values { native_schema(_1) }
      return rest unless node.key?(:type)   # a properties map, whose keys are field names

      limits = node.slice(*NUMERIC_LIMITS)
      return rest if limits.empty?

      note = limits.map { "#{_1} #{_2}" }.join(", ")
      rest.except(*NUMERIC_LIMITS).merge(description: [ node[:description], note ].compact.join(". "))
    end

    def probe_embedding(_model, timeout:) = raise(Ai::Error::Refused, "Anthropic has no embedding models")

    # RubyLLM has no public per-context model listing, so this is a plain GET through
    # Faraday with Ai::Transport::Http's proxy and TLS options, as every other call gets, so the
    # probe takes the same path as the calls it vouches for.
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

    # A body that isn't Anthropic's error shape still maps by its status.
    def models_error(status, body)
      error = body.is_a?(Hash) ? body["error"] : nil
      message = (error.is_a?(Hash) ? error["message"] : error&.to_s).presence || "HTTP #{status}"
      return Ai::Error::ModelMissing.new(message, status:) if missing_model?(status, body)

      Ai::Error.from_status(status, message, body:)
    end

    def ruby_llm_provider = :anthropic
    def ruby_llm_api_base = endpoint.base_url.presence || DEFAULT_BASE

    def configure_provider(config)
      config.anthropic_api_key = endpoint.api_key
      config.anthropic_api_base = endpoint.base_url if endpoint.base_url.present?
    end
end
