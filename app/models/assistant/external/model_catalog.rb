# Discovers the agents an external assistant gateway exposes. Same wire format
# as any OpenAI-compatible /models endpoint, but the ids are agents
# (openclaw/main, ...) and the configured URL is the full chat completions URL.
class Assistant::External::ModelCatalog < Provider::Openai::ModelCatalog
  def initialize(url:, token:, open_timeout: 5, read_timeout: 10)
    @url = url
    super(uri_base: url, token: token, open_timeout: open_timeout, read_timeout: read_timeout)
  end

  private
    def models_uri
      uri = http_uri(@url)
      path = uri.path.sub(%r{/chat/completions/?\z}, "/models")
      raise URI::InvalidURIError, I18n.t("assistant.external.model_catalog.errors.chat_completions_required") if path == uri.path

      uri.path = path
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def label_for(id)
      case id
      when "openclaw", "openclaw/default"
        I18n.t("assistant.external.model_catalog.default_agent_label", id: id)
      when %r{\Aopenclaw/(.+)\z}
        I18n.t("assistant.external.model_catalog.named_agent_label", name: $1, id: id)
      else id
      end
    end

    # The gateway has its own URL and token; OPENAI_EXTRA_HEADERS belong to
    # the builtin provider.
    def extra_headers
      {}
    end

    def i18n_scope
      "assistant.external.model_catalog"
    end
end
