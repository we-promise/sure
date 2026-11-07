# Builds the provider an eval run exercises.
#
# Separate from Provider::Registry because evals need per-run overrides the
# registry deliberately does not accept: a model chosen per run, credentials
# from the run's own config, and provider knobs like Jev's concurrency. The
# registry answers "what is this install configured to use"; this answers "what
# is this particular run measuring".
#
# Both Eval::Runners::Base and Eval::Langfuse::ExperimentRunner call this. They
# previously carried their own copies, so adding a provider meant two edits with
# no failure signal if you made only one.
class Eval::ProviderFactory
  Error = Class.new(StandardError)

  # config arrives as jsonb (string keys) from Eval::Run and as a plain hash
  # from ExperimentRunner, so it is normalized rather than trusted either way.
  def self.build(provider:, model:, config: {})
    new(provider: provider, model: model, config: config).build
  end

  def initialize(provider:, model:, config: {})
    @provider = provider.to_s
    @model = model
    @config = (config || {}).with_indifferent_access
  end

  def build
    case provider
    when "openai" then build_openai
    when "jev" then build_jev
    else raise Error, "Unsupported provider: #{provider}"
    end
  end

  private
    attr_reader :provider, :model, :config

    # The run's OpenAI-compatible endpoint: its own token and URL, else the install's (Ai::Config,
    # from the deprecated ENV or Settings until PR 7). Categorization and merchant detection run
    # through the generations; chat through Provider::Openai until PR 6.
    def build_openai
      installed = Ai::Config.current.endpoints.find { _1.protocol == :compatible && _1.name.start_with?("openai") }
      access_token = config[:access_token].presence || installed&.api_key
      raise Error, "OpenAI access token not configured" unless access_token.present?

      uri_base = config[:uri_base].presence || installed&.base_url
      endpoint = Ai::Config::Endpoint.new(
        name: uri_base ? "openai_compatible" : "openai", protocol: :compatible, preset: (:openai unless uri_base),
        base_url: uri_base, api_key: access_token, responses_api: uri_base.nil?,
        location: uri_base.to_s.start_with?("http:") ? :local : :cloud, timeout_seconds: installed&.timeout_seconds || 60,
        json_mode: installed&.json_mode || :auto
      )
      Eval::GenerationClient.new(endpoint:, model:, chat_provider: Provider::Openai.new(access_token, uri_base:, model:))
    end

    def build_jev
      api_key = config[:api_key].presence || Provider::Jev.api_key # pipelock:ignore

      raise Error, "Jev API key not configured" unless api_key.present?

      Provider::Jev.new(
        api_key,
        endpoint: config[:endpoint].presence || Provider::Jev.effective_endpoint,
        model: model,
        concurrency: config[:concurrency]
      )
    end
end
