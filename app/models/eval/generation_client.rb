# What an eval run calls for categorization and merchant detection: the same generations
# production runs (Ai::Generations::*), on the run's own endpoint and model, so an eval measures
# the shipped prompts, JSON policy and coercion. On a Jev endpoint, the generation's judgement
# answers, with each answer's confidence. Answers come back as the Provider::Response the runners
# read. Chat evals go through Provider::Openai, as chat does.
class Eval::GenerationClient
  Categorization = Data.define(:transaction_id, :category_name, :confidence, :probabilities) do
    def initialize(transaction_id:, category_name:, confidence: nil, probabilities: nil) = super
  end
  DetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  delegate :chat_response, to: :chat_provider

  # How many items `client` takes per call for `feature`, so a runner slices samples the way the
  # measured model would: its own batch size, or the installed route's for a client that isn't one
  # of these (Jev).
  def self.batch_size_for(client, feature)
    client.is_a?(self) ? client.ai_config(feature).batch_size_for(feature) : Ai::Config.current.batch_size_for(feature)
  end

  # endpoint: the Ai::Config::Endpoint the run measures; model: its model name; budget: the
  # installed model whose context window, output limit and batch size the run keeps.
  def initialize(endpoint:, model:, budget: nil, chat_provider: nil)
    @endpoint, @model_name, @budget, @chat_provider = endpoint, model, budget, chat_provider
  end

  # json_mode overrides every request's (the Langfuse runner forces strict on null-heavy batches).
  def auto_categorize(transactions:, user_categories:, json_mode: nil, **)
    respond(:categorize, json_mode) do
      value = Ai::Generations::CategorizeTransactions.new(transactions:, categories: user_categories, family: nil).call!
      value[:categorizations].map { Categorization.new(**_1.slice(:transaction_id, :category_name, :confidence, :probabilities)) }
    end
  end

  def auto_detect_merchants(transactions:, user_merchants:, json_mode: nil, **)
    respond(:detect_merchants, json_mode) do
      value = Ai::Generations::DetectMerchants.new(transactions:, merchants: user_merchants, family: nil).call!
      value[:merchants].map { DetectedMerchant.new(**_1.slice(:transaction_id, :business_name, :business_url)) }
    end
  end

  # A one-route config for `feature` on the run's model, with the prompt variant for this kind
  # of endpoint.
  def ai_config(feature, json_mode: nil)
    judge = @endpoint.protocol == :jev
    model = Ai::Config::Model.new(endpoint: @endpoint, name: @model_name,
                                  capabilities: judge ? Ai::LegacyEnvConfig::Jev.capabilities(@endpoint, model: @model_name) : %i[structured_output],
                                  context_window: (@budget ? @budget.context_window : (Assistant::TokenBudget.context_window if Provider::Openai.custom_endpoint?(@endpoint.base_url)) unless judge),
                                  max_output_tokens: @budget&.max_output_tokens,
                                  batch_size: @budget&.batch_size || Ai::Config::Model::DEFAULT_BATCH_SIZE)
    route = Ai::Route.new(feature:, model:, json_mode: json_mode.presence,
                          prompt: Ai::LegacyEnvConfig.prompt_for(feature, @endpoint))
    Ai::Config.new(endpoints: [ @endpoint ], models: [ model ], routes: { feature => [ route ] })
  end

  private
    attr_reader :chat_provider

    def respond(feature, json_mode)
      data = Ai::Config.with(ai_config(feature, json_mode:)) { yield }
      Provider::Response.new(success?: true, data:, error: nil)
    rescue Ai::Error::Base => error
      Provider::Response.new(success?: false, data: nil, error:)
    end
end
