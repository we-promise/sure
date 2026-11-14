# Every instance-wide AI value a process uses: endpoints, their models, and one ordered list of
# routes per feature. Every AI feature reads it through Ai::Router; nothing else reads AI ENV or
# AI `Setting` fields (cop Sure/NoAiEnv).
#
# Ai::LegacyEnvConfig builds it in each process from the AI ENV and `Setting` fields, so the web
# and the workers can disagree when their ENV differs.
class Ai::Config
  attr_reader :endpoints, :models, :routes, :vector_store_backend

  # vector_store_backend: :openai (the `embed` route's endpoint is a vector store), :pgvector,
  # :qdrant, or nil when no store is configured.
  def initialize(endpoints: [], models: [], routes: {}, vector_store_backend: nil)
    @endpoints = endpoints.freeze
    @models = models.freeze
    @routes = routes.transform_keys(&:to_sym).transform_values(&:freeze).freeze
    @vector_store_backend = vector_store_backend&.to_sym
    freeze
  end

  class << self
    # The snapshot for this request or job, rebuilt when its ENV or `Setting` inputs change.
    def current
      return @override if @override

      fingerprint = Ai::LegacyEnvConfig.fingerprint
      unless Current.config && Current.fingerprint == fingerprint
        Current.config, Current.fingerprint = Ai::LegacyEnvConfig.build, fingerprint
      end
      Current.config
    end

    # A fixed snapshot used instead of the built one, in every request and job until reset.
    # For tests (AiTestHelper#use_ai_routes, #use_no_ai).
    attr_writer :override
  end

  def routes_for(feature) = routes.fetch(feature.to_sym, [])

  def endpoint(name) = endpoints.find { _1.name == name.to_s }

  # The model pgvector and Qdrant embed with: the `embed` route's, or one no route uses yet
  # (pgvector without its extension). Nil when documents go to a vector store endpoint.
  def embedding_model
    candidates = routes_for(:embed).map(&:model) + models.select { _1.capable?(:embedding) }
    candidates.find { !_1.endpoint.vector_store? }
  end

  def model(endpoint_name, name) = models.find { _1.endpoint.name == endpoint_name.to_s && _1.name == name.to_s }

  def inspect = "#<Ai::Config #{endpoints.map(&:name).join(", ")}; routes: #{routes.keys.join(", ")}>"
  alias_method :to_s, :inspect
end
