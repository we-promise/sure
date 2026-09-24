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
      uri = URI(@url)
      raise URI::InvalidURIError, "only HTTP and HTTPS endpoints are supported" unless uri.is_a?(URI::HTTP)

      path = uri.path.sub(%r{/chat/completions/?\z}, "/models")
      raise URI::InvalidURIError, "endpoint must end in /chat/completions" if path == uri.path

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

    def error_subject
      "Agent discovery"
    end
end
