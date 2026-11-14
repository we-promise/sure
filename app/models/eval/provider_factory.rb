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
    # from the deprecated ENV or Settings). Categorization and merchant detection run through the
    # generations; chat through Provider::Openai.
    def build_openai
      installed = Ai::Config.current.endpoints.find { _1.protocol == :compatible && _1.name.start_with?("openai") }
      access_token = config[:access_token].presence || installed&.api_key
      raise Error, "OpenAI access token not configured" unless access_token.present?

      uri_base = config[:uri_base].presence || installed&.base_url
      # A regional OpenAI host (us.api.openai.com) is native OpenAI, not a custom server (#4836).
      custom = Provider::Openai.custom_endpoint?(uri_base)
      own_server = installed && uri_base == installed.base_url
      endpoint =
        if own_server
          # The install's own server: its headers, API choice and timeout, as production calls it.
          installed.with(api_key: access_token)
        else
          Ai::Config::Endpoint.new(
            name: custom ? "openai_compatible" : "openai", protocol: :compatible, preset: (:openai unless custom),
            base_url: uri_base, api_key: access_token, responses_api: !custom,
            location: uri_base.to_s.start_with?("http:") ? :local : :cloud, timeout_seconds: installed&.timeout_seconds || 60,
            json_mode: installed&.json_mode || :auto
          )
        end
      # The installed model's limits only when the eval runs that model on that server.
      budget = Ai::Config.current.models.find { _1.endpoint == installed && _1.name == model } if own_server
      Eval::GenerationClient.new(endpoint:, model:, budget:, chat_provider: Provider::Openai.new(access_token, uri_base:, model:))
    end

    # The run's Jev endpoint, else the install's: categorization through the generation's
    # judgement, as production runs it.
    def build_jev
      jev = Ai::LegacyEnvConfig::Jev
      api_key = config[:api_key].presence || jev.api_key # pipelock:ignore
      raise Error, "Jev API key not configured" unless api_key.present?

      url = config[:endpoint].presence || jev.effective_endpoint
      if (reason = jev.unreachable_reason(url))
        raise Error, "Jev endpoint not supported: #{jev.redacted_endpoint(url)}: #{jev::UNSUPPORTED.fetch(reason)}"
      end

      endpoint = jev.endpoint(url, api_key:, timeout_seconds: 30, parallel_requests: config[:concurrency])
      Eval::GenerationClient.new(endpoint:, model:)
    end
end
