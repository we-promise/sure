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

    def build_openai
      access_token = config[:access_token].presence ||
                     ENV["OPENAI_ACCESS_TOKEN"].presence ||
                     Setting.openai_access_token

      raise Error, "OpenAI access token not configured" unless access_token.present?

      uri_base = config[:uri_base].presence ||
                 ENV["OPENAI_URI_BASE"].presence ||
                 Setting.openai_uri_base

      Provider::Openai.new(access_token, uri_base: uri_base, model: model)
    end

    def build_jev
      api_key = config[:api_key].presence || Provider::Jev.api_key

      raise Error, "Jev API key not configured" unless api_key.present?

      Provider::Jev.new(
        api_key,
        endpoint: config[:endpoint].presence || Provider::Jev.effective_endpoint,
        model: model,
        concurrency: config[:concurrency]
      )
    end
end
