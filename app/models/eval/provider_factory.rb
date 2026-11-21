# Builds the provider an eval run exercises.
#
# Separate from Provider::Registry because evals need per-run overrides the
# registry deliberately does not accept: a model chosen per run, credentials
# from the run's own config, and provider knobs like Jev's concurrency. The
# registry answers "what is this install configured to use"; this answers "what
# is this particular run measuring".
#
# Both Eval::Runners::Base and Eval::Langfuse::ExperimentRunner call this, so a
# provider is added in one place.
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
      # The configured URL even when the install has no token to build its endpoint with: a run
      # that brings its own token must still reach the gateway, not OpenAI.
      configured_url = Ai::LegacyEnvConfig.openai_uri_base
      uri_base = config[:uri_base].presence || installed&.base_url || configured_url
      own_server = installed && same_server?(uri_base, installed.base_url)
      # The install's key goes only to the install's server; a run on another one brings its own.
      access_token = config[:access_token].presence || (installed.api_key if own_server)
      raise Error, "OpenAI access token not configured" unless access_token.present?

      # A regional OpenAI host (us.api.openai.com) is native OpenAI, not a custom server (#4836).
      custom = Provider::Openai.custom_endpoint?(uri_base)
      # The configured gateway without an installed endpoint still needs its static headers; a
      # server of the run's own never gets them.
      gateway_headers = installed.nil? && configured_url && same_server?(uri_base, configured_url) ? Ai::LegacyEnvConfig.static_openai_headers : {}
      chat_provider = Provider::Openai.new(access_token, uri_base:, model:)
      endpoint =
        if own_server
          # The install's own server: its headers, API choice and timeout, as production calls it.
          installed.with(api_key: access_token)
        else
          Ai::Config::Endpoint.new(
            name: custom ? "openai_compatible" : "openai", protocol: :compatible, preset: (:openai unless custom),
            base_url: uri_base, api_key: access_token, extra_headers: gateway_headers,
            responses_api: chat_provider.supports_responses_endpoint?,   # OPENAI_SUPPORTS_RESPONSES_ENDPOINT, as production
            # With no installed endpoint, the operator's OPENAI_REQUEST_TIMEOUT and JSON mode, as production.
            location: Ai::Config::Endpoint.location_for(uri_base),
            timeout_seconds: installed&.timeout_seconds || Provider::Openai.request_timeout,
            json_mode: installed&.json_mode || Ai::LegacyEnvConfig.openai_json_mode
          )
        end
      # The installed model's limits only when the eval runs that model on that server.
      budget = Ai::Config.current.models.find { _1.endpoint == installed && _1.name == model } if own_server
      Eval::GenerationClient.new(endpoint:, model:, budget:, chat_provider:)
    end

    # As the transport reaches them: `…/v1` and `…/v1/` are one server.
    def same_server?(url, other) = Ai::Transport::Http.compatible_base(url) == Ai::Transport::Http.compatible_base(other)

    # The run's Jev endpoint, else the install's: categorization through the generation's
    # judgement, as production runs it.
    def build_jev
      jev = Ai::LegacyEnvConfig::Jev
      url = config[:endpoint].presence || jev.effective_endpoint
      # The install's key goes only to the install's endpoint; a run on another one brings its own.
      own_endpoint = url.to_s.chomp("/") == jev.effective_endpoint.to_s.chomp("/")
      api_key = config[:api_key].presence || (jev.api_key if own_endpoint) # pipelock:ignore
      raise Error, "Jev API key not configured" unless api_key.present?

      if (reason = jev.unreachable_reason(url))
        raise Error, "Jev endpoint not supported: #{jev.endpoint_origin(url)}: #{jev::UNSUPPORTED.fetch(reason)}"
      end

      endpoint = jev.endpoint(url, api_key:, timeout_seconds: 30, parallel_requests: config[:concurrency])
      Eval::GenerationClient.new(endpoint:, model:)
    end
end
